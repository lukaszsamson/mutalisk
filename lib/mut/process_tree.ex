defmodule Mut.ProcessTree do
  @moduledoc """
  Tree-aware OS-process termination for spawned Ports.

  A `Port.open({:spawn_executable, ...})` reports the os_pid of the **immediate**
  child. Under a version manager (asdf/mise) or a wrapper-script `mix`, that
  immediate child is a shell/launcher that forks the real `elixir` → `beam.smp`.
  Killing only the immediate pid orphans the BEAM — which, on the timeout hot
  path, is exactly the (frequently infinite-looping) mutant VM we are trying to
  reap. `kill_port/1` walks the descendant tree (`pgrep -P`) and signals the
  whole tree (TERM, then KILL) so no BEAM is left behind.

  Shared by `Mut.Worker` (timeout path) and `Mut.ChildProcess` (recompile path)
  so the two cannot drift — historically only `ChildProcess` tree-killed, and
  `Worker` leaked the BEAM on managed installs (see review).
  """

  @doc """
  Close `port` and terminate its OS process tree. Best-effort: never raises
  (a closed port / already-dead pid / missing `pgrep` all degrade to `:ok`).
  """
  @spec kill_port(port()) :: :ok
  def kill_port(port) do
    os_pid = Port.info(port, :os_pid)
    Port.close(port)

    case os_pid do
      {:os_pid, pid} when is_integer(pid) -> kill_process_tree(pid)
      _unknown -> :ok
    end
  catch
    _kind, _reason -> :ok
  end

  @doc "Signal `pid` and all its descendants: TERM, brief grace, then KILL."
  @spec kill_process_tree(non_neg_integer()) :: :ok
  def kill_process_tree(pid) do
    descendants = descendant_pids(pid)

    Enum.each(descendants, &kill_pid(&1, "-TERM"))
    kill_pid(pid, "-TERM")
    Process.sleep(100)

    # Re-scan before KILL and signal the union: a wrapper can fork a child
    # (e.g. the real `beam.smp`) AFTER the first snapshot, so a single
    # pre-TERM snapshot would orphan a late fork on the timeout path. The
    # union of the original snapshot and a fresh scan covers both the
    # already-known descendants and any that appeared during the grace window.
    (descendants ++ descendant_pids(pid))
    |> Enum.uniq()
    |> Enum.each(&kill_pid(&1, "-KILL"))

    kill_pid(pid, "-KILL")
    :ok
  end

  defp descendant_pids(pid) do
    pid
    |> child_pids()
    |> Enum.flat_map(fn child_pid -> [child_pid | descendant_pids(child_pid)] end)
  end

  defp child_pids(pid) do
    case System.cmd("pgrep", ["-P", Integer.to_string(pid)], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.flat_map(&parse_pid/1)

      _no_children ->
        []
    end
  end

  defp parse_pid(value) do
    case Integer.parse(value) do
      {child_pid, ""} -> [child_pid]
      _invalid -> []
    end
  end

  defp kill_pid(pid, signal) do
    System.cmd("kill", [signal, Integer.to_string(pid)], stderr_to_stdout: true)
  end
end
