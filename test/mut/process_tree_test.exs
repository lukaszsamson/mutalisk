defmodule Mut.ProcessTreeTest do
  use ExUnit.Case, async: false

  @moduledoc """
  M99 #3: the timeout hot path must reap the WHOLE spawned process tree, not
  just the immediate os_pid. Under a version-manager / wrapper `mix`, the
  immediate child forks the real `beam.smp`; a single `kill` would orphan it.
  """

  alias Mut.ProcessTree

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

    # Drain/close the port so we don't leak it in the test process.
    receive do
      {^port, {:exit_status, _}} -> :ok
    after
      500 -> (Port.info(port) && Port.close(port)) || :ok
    end
  end

  @tag :tmp_processes
  test "kill_port/2 falls back to the known os_pid when the port's os_pid is already nil" do
    sleep = System.find_executable("sleep")
    sh = System.find_executable("sh")
    assert sleep && sh, "sleep and sh required for this test"

    # A process the port itself knows nothing about — standing in for the
    # descendant (e.g. beam.smp) of a wrapper `mix`/`elixir` that has already
    # exited by the time the timeout path runs cleanup. `kill_port/2` is only
    # told about it via `known_os_pid`.
    decoy_port = Port.open({:spawn_executable, sleep}, [:binary, :exit_status, args: ["60"]])
    {:os_pid, decoy_pid} = Port.info(decoy_port, :os_pid)
    assert alive?(decoy_pid), "decoy process should be running before the kill"

    # A real port whose own OS process has already exited, so Port.info/2
    # legitimately returns nil for it — same shape as the wrapper-already-gone
    # race — while the port itself has NOT been closed yet (this is the first
    # close, exactly as on the real timeout path).
    port = Port.open({:spawn_executable, sh}, [:binary, :exit_status, args: ["-c", "exit 0"]])

    receive do
      {^port, {:exit_status, _}} -> :ok
    after
      2000 -> flunk("sh did not exit")
    end

    assert Port.info(port, :os_pid) == nil

    :ok = ProcessTree.kill_port(port, decoy_pid)

    assert eventually(fn -> not alive?(decoy_pid) end),
           "kill_port/2 must reap the known_os_pid process even though " <>
             "Port.info/2 can no longer report the port's own os_pid"
  end

  test "kill_port/2 returns :ok with no known os_pid and a port whose os_pid is unavailable" do
    sh = System.find_executable("sh")
    assert sh, "sh required for this test"

    port = Port.open({:spawn_executable, sh}, [:binary, :exit_status, args: ["-c", "exit 0"]])

    receive do
      {^port, {:exit_status, _}} -> :ok
    after
      2000 -> flunk("sh did not exit")
    end

    # The port is dead (child already exited) and no known_os_pid was given —
    # this must degrade to :ok, not raise.
    assert :ok = ProcessTree.kill_port(port, nil)
  end

  defp await_child_pid(port) do
    receive do
      {^port, {:data, data}} ->
        case data |> String.trim() |> Integer.parse() do
          {pid, _} -> pid
          :error -> await_child_pid(port)
        end
    after
      2000 -> flunk("did not receive the forked child pid")
    end
  end

  # `kill -0` alone is not enough: the process stays visible (and answers
  # `kill -0` successfully) as a zombie until its parent (the BEAM, which
  # forked it) reaps it, even after TERM/KILL have done their job. Treat a
  # zombie as dead too, or a test can hang waiting for OS-level reaping that
  # has nothing to do with the code under test.
  defp alive?(pid) do
    case System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_, 0} -> not zombie?(pid)
      _not_found -> false
    end
  end

  defp zombie?(pid) do
    case System.cmd("ps", ["-o", "state=", "-p", Integer.to_string(pid)], stderr_to_stdout: true) do
      {output, 0} -> output |> String.trim() |> String.starts_with?("Z")
      _no_such_process -> true
    end
  end

  defp eventually(fun, attempts \\ 30) do
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
