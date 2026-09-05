defmodule Mut.ProcessTreeTest do
  use ExUnit.Case, async: false

  @moduledoc """
  M99 #3: the timeout hot path must reap the WHOLE spawned process tree, not
  just the immediate os_pid. Under a version-manager / wrapper `mix`, the
  immediate child forks the real `beam.smp`; a single `kill` would orphan it.

  T32: and it must still reap it when the wrapper has ALREADY EXITED by the
  time cleanup runs — the descendant is then reparented to pid 1, the port's
  os_pid is `nil`, and only a process-group kill can reach it.
  """

  alias Mut.ProcessTree

  describe "launcher detection" do
    test "detects a probed launcher and caches it" do
      launcher = ProcessTree.launcher()

      case launcher do
        {name, path} ->
          assert name in [:perl, :setsid]
          assert File.exists?(path)

        :none ->
          refute System.find_executable("perl") || System.find_executable("setsid"),
                 "a launcher exists on this machine but was not detected"
      end

      assert ProcessTree.launcher() == launcher, "launcher detection must be cached"
    end

    test "spawn_command wraps the executable in the launcher, or passes it through" do
      {executable, args} = ProcessTree.spawn_command("/bin/echo", ["hi", "there"])

      case ProcessTree.launcher() do
        {:perl, perl} ->
          assert executable == perl
          assert ["-e", script, "/bin/echo", "hi", "there"] = args
          assert script =~ "setpgrp"

        {:setsid, setsid} ->
          assert executable == setsid
          assert args == ["-w", "/bin/echo", "hi", "there"]

        :none ->
          assert executable == "/bin/echo"
          assert args == ["hi", "there"]
      end
    end

    test "the launcher preserves exit status, merged stderr and cwd/env" do
      script = "pwd; printf 'to-stderr\\n' >&2; printf '%s\\n' \"$MUT_TEST_VAR\"; exit 3"
      {executable, args} = ProcessTree.spawn_command("/bin/sh", ["-c", script])

      port =
        Port.open({:spawn_executable, executable}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          {:args, args},
          {:cd, "/tmp"},
          {:env, [{~c"MUT_TEST_VAR", ~c"from-env"}]}
        ])

      {status, output} = await_exit(port)

      assert status == 3, "the launcher must not swallow the child's exit status"
      assert output =~ "to-stderr", ":stderr_to_stdout must still capture stderr"
      assert output =~ "from-env", ":env must still reach the child"
      assert output =~ "tmp", ":cd must still apply (got: #{inspect(output)})"
    end
  end

  describe "kill_port/2 with an already-exited wrapper (T32)" do
    @describetag :tmp_processes

    test "reaps a reparented descendant whose wrapper exited and closed the pipe" do
      # The `sleep` gets its own stdout/stderr, so when `sh` exits the port's
      # pipe closes too — a shim that fully detaches what it launched.
      assert_reaps_reparented_descendant("sleep 60 >/dev/null 2>&1 & echo $!; read go; exit 0")
    end

    test "reaps a reparented descendant that keeps the wrapper's stdout pipe open" do
      # The descendant inherits stdout, so the port's pipe stays open after the
      # wrapper exits — the shape an asdf/mise `mix` shim that backgrounds the
      # real `beam.smp` actually has.
      assert_reaps_reparented_descendant("sleep 60 & echo $!; read go; exit 0")
    end
  end

  defp assert_reaps_reparented_descendant(script) do
    {executable, args} = ProcessTree.spawn_command("/bin/sh", ["-c", script])

    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        {:args, args}
      ])

    # The wrapper blocks on `read` until we release it, so the snapshot below
    # is taken while it is still alive — exactly as production does right after
    # Port.open/2 — with no race against a fast-exiting shim.
    identity = ProcessTree.identify(port)
    assert %{os_pid: _, pgid: pgid} = identity

    if ProcessTree.launcher() != :none do
      assert is_integer(pgid),
             "with a launcher the child must lead its own group (got #{inspect(identity)})"
    end

    orphan = await_child_pid(port)
    assert alive?(orphan), "the backgrounded descendant should be running"

    # Release the wrapper: it exits, the descendant is reparented to pid 1.
    Port.command(port, "go\n")

    # Wait until the wrapper is really gone. This is the reviewer's
    # reproduction: by the time cleanup runs the immediate child is dead, so
    # `Port.info(port, :os_pid)` is either nil (pipe closed with it) or a stale
    # pid — the pid path has nothing left to walk from.
    assert eventually(fn -> not alive?(identity.os_pid) end),
           "the wrapper must have exited before cleanup runs"

    assert alive?(orphan), "the reparented descendant must outlive the wrapper"

    :ok = ProcessTree.kill_port(port, identity)

    if is_integer(pgid) do
      assert eventually(fn -> not alive?(orphan) end),
             "the reparented descendant (the would-be orphaned BEAM) must be reaped"
    end

    drain(port)
  end

  @tag :tmp_processes
  test "Mut.ChildProcess timeout reaps a grandchild whose own parent already exited" do
    # The faithful T32 shape through a real caller: the inner `sh` backgrounds
    # a `sleep` and exits, so the `sleep` is reparented to pid 1 and is no
    # longer reachable from the port's os_pid by any `pgrep -P` walk. Only the
    # process group still holds it.
    script = "sh -c 'sleep 60 & echo $!'; sleep 30"

    assert {:timeout, output} =
             Mut.ChildProcess.run("/bin/sh", ["-c", script], timeout_ms: 700)

    assert {orphan, _rest} = output |> String.trim() |> Integer.parse()

    if ProcessTree.launcher() != :none do
      assert eventually(fn -> not alive?(orphan) end),
             "the reparented grandchild must be reaped by the group kill"
    end
  end

  @tag :tmp_processes
  test "kill_process_tree reaps a forked child, not just the wrapper" do
    sh = System.find_executable("sh")
    assert sh, "sh required for this test"

    # `sh` forks a long `sleep` (the "real BEAM" a wrapper would launch),
    # prints its pid, then waits — so the sleep is a live child of sh.
    port =
      Port.open({:spawn_executable, sh}, [
        :binary,
        :exit_status,
        args: ["-c", "sleep 60 & echo $!; wait"]
      ])

    child_pid = await_child_pid(port)
    {:os_pid, wrapper_pid} = Port.info(port, :os_pid)

    assert alive?(child_pid), "forked child should be running before the kill"
    assert alive?(wrapper_pid), "wrapper should be running before the kill"

    :ok = ProcessTree.kill_process_tree(wrapper_pid)

    assert eventually(fn -> not alive?(child_pid) end),
           "the forked child (the would-be orphaned BEAM) must be reaped"

    assert eventually(fn -> not alive?(wrapper_pid) end),
           "the wrapper must be reaped"

    drain(port)
  end

  @tag :tmp_processes
  test "the pgrep -P fallback still reaps the tree when no launcher is used" do
    sh = System.find_executable("sh")
    assert sh, "sh required for this test"

    # Spawned WITHOUT spawn_command/2 — the no-launcher path. The wrapper is
    # still alive, so the descendant walk is the mechanism under test.
    port =
      Port.open({:spawn_executable, sh}, [
        :binary,
        :exit_status,
        args: ["-c", "sleep 60 & echo $!; wait"]
      ])

    child_pid = await_child_pid(port)
    identity = ProcessTree.identify(port)

    :ok = ProcessTree.kill_port(port, identity)

    assert eventually(fn -> not alive?(child_pid) end),
           "the descendant must be reaped by the pid walk / group kill"
  end

  @tag :tmp_processes
  test "kill_port/2 falls back to the verified known os_pid when the port's os_pid is nil" do
    sleep = System.find_executable("sleep")
    sh = System.find_executable("sh")
    assert sleep && sh, "sleep and sh required for this test"

    # A process the port itself knows nothing about — standing in for a
    # descendant that outlived its wrapper. `kill_port/2` is only told about it
    # via the identity snapshot, and only the pid path can reach it (the
    # snapshot below is hand-built with no pgid).
    decoy_port = Port.open({:spawn_executable, sleep}, [:binary, :exit_status, args: ["60"]])
    %{os_pid: decoy_pid, start_time: decoy_start} = ProcessTree.identify(decoy_port)
    assert alive?(decoy_pid), "decoy process should be running before the kill"

    port = Port.open({:spawn_executable, sh}, [:binary, :exit_status, args: ["-c", "exit 0"]])
    assert eventually(fn -> Port.info(port, :os_pid) == nil end)

    # A bare pid (no start-time snapshot) must never be signalled: the OS may
    # have recycled it (review W4-1).
    :ok = ProcessTree.kill_port(port, decoy_pid)
    assert alive?(decoy_pid), "an unverifiable bare pid must not be killed"

    # A stale identity (right pid, wrong start time) must not be signalled either.
    stale = %{os_pid: decoy_pid, start_time: "Thu Jan  1 00:00:00 1970", pgid: nil}
    :ok = ProcessTree.kill_port(port, stale)
    assert alive?(decoy_pid), "a pid whose start time no longer matches must not be killed"

    :ok = ProcessTree.kill_port(port, %{os_pid: decoy_pid, start_time: decoy_start, pgid: nil})

    assert eventually(fn -> not alive?(decoy_pid) end),
           "kill_port/2 must reap the known os_pid process even though " <>
             "Port.info/2 can no longer report the port's own os_pid"

    drain(decoy_port)
  end

  test "kill_port/2 never signals this VM's own process group" do
    sh = System.find_executable("sh")
    assert sh, "sh required for this test"

    port = Port.open({:spawn_executable, sh}, [:binary, :exit_status, args: ["-c", "exit 0"]])
    assert eventually(fn -> Port.info(port, :os_pid) == nil end)

    {own, 0} = System.cmd("ps", ["-o", "pgid=", "-p", System.pid()])
    own_pgid = own |> String.trim() |> String.to_integer()

    # If this were signalled the test VM would die, taking the suite with it.
    assert :ok =
             ProcessTree.kill_port(port, %{os_pid: nil, start_time: nil, pgid: own_pgid})

    assert Process.alive?(self())
  end

  test "kill_port/2 returns :ok with no known os_pid and a port whose os_pid is unavailable" do
    sh = System.find_executable("sh")
    assert sh, "sh required for this test"

    port = Port.open({:spawn_executable, sh}, [:binary, :exit_status, args: ["-c", "exit 0"]])
    assert eventually(fn -> Port.info(port, :os_pid) == nil end)

    # The port is dead (child already exited) and no identity was given —
    # this must degrade to :ok, not raise.
    assert :ok = ProcessTree.kill_port(port, nil)
  end

  defp await_exit(port, output \\ "") do
    receive do
      {^port, {:data, data}} -> await_exit(port, output <> data)
      {^port, {:exit_status, status}} -> {status, output}
    after
      5000 -> flunk("port did not exit")
    end
  end

  defp await_child_pid(port) do
    receive do
      {^port, {:data, data}} ->
        case data |> String.trim() |> Integer.parse() do
          {pid, _rest} -> pid
          :error -> await_child_pid(port)
        end
    after
      5000 -> flunk("did not receive the forked child pid")
    end
  end

  defp drain(port) do
    receive do
      {^port, {:exit_status, _status}} -> :ok
      {^port, {:data, _data}} -> drain(port)
    after
      100 -> (Port.info(port) && safe_close(port)) || :ok
    end
  end

  defp safe_close(port) do
    Port.close(port)
  catch
    _kind, _reason -> :ok
  end

  # `kill -0` alone is not enough: the process stays visible (and answers
  # `kill -0` successfully) as a zombie until its parent (the BEAM, which
  # forked it) reaps it, even after TERM/KILL have done their job. Treat a
  # zombie as dead too, or a test can hang waiting for OS-level reaping that
  # has nothing to do with the code under test.
  defp alive?(pid) do
    case System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_output, 0} -> not zombie?(pid)
      _not_found -> false
    end
  end

  defp zombie?(pid) do
    case System.cmd("ps", ["-o", "state=", "-p", Integer.to_string(pid)], stderr_to_stdout: true) do
      {output, 0} -> output |> String.trim() |> String.starts_with?("Z")
      _no_such_process -> true
    end
  end

  defp eventually(fun, attempts \\ 60) do
    cond do
      fun.() ->
        true

      attempts <= 0 ->
        false

      true ->
        Process.sleep(50)
        eventually(fun, attempts - 1)
    end
  end
end
