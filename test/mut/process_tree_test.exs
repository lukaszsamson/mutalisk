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

  defp alive?(pid) do
    match?({_, 0}, System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true))
  end

  defp eventually(fun, attempts \\ 30) do
    cond do
      fun.() -> true
      attempts <= 0 -> false
      true -> Process.sleep(50) and eventually(fun, attempts - 1)
    end
  end
end
