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

  `known`, when given, is the `identify/1` snapshot taken right after
  `Port.open/2` and is used if `Port.info(port, :os_pid)` returns `nil` (T32:
  a non-exec asdf/mise-style wrapper can have already exited — and the port
  along with it — by the time cleanup runs, even though its descendant, e.g.
  the real `beam.smp`, is still alive). A `nil` os_pid also means the OS may
  have reaped the wrapper and RECYCLED its pid, so the snapshot's process start
  time is re-checked before anything is signalled; a mismatch (or a bare
  integer with no start time) kills nothing.
  """
  @spec kill_port(port(), identity() | non_neg_integer() | nil) :: :ok
  def kill_port(port, known \\ nil) do
    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} when is_integer(pid) -> pid
        _unknown -> verified_known_pid(known)
      end

    # Port.close/1 raises if the port already auto-closed (e.g. its
    # :exit_status was already delivered) — that must NOT skip the
    # process-tree kill below, or `known_os_pid` cleanup (the whole point of
    # T32) would be defeated by the very close call meant to precede it.
    safe_close(port)

    case os_pid do
      pid when is_integer(pid) -> kill_process_tree(pid)
      _unknown -> :ok
    end
  catch
    _kind, _reason -> :ok
  end

  @typedoc "An OS pid plus its process start time, from `identify/1`."
  @type identity :: {non_neg_integer(), String.t()}

  @doc """
  Snapshot `{os_pid, start_time}` for `port`'s immediate child, or `nil` when
  the port has no os_pid (already gone) or `ps` cannot report it. Take it right
  after `Port.open/2` and hand it to `kill_port/2`.
  """
  @spec identify(port()) :: identity() | nil
  def identify(port) do
    with {:os_pid, pid} when is_integer(pid) <- Port.info(port, :os_pid),
         start when is_binary(start) <- start_time(pid) do
      {pid, start}
    else
      _unknown -> nil
    end
  end

  defp verified_known_pid({pid, start}) when is_integer(pid) and is_binary(start) do
    if start_time(pid) == start, do: pid, else: nil
  end

  defp verified_known_pid(_unverifiable), do: nil

  # `ps -o lstart=` prints the process start time to the second; equal pid AND
  # equal start time is as close to a unique process identity as portable
  # tooling gets.
  defp start_time(pid) do
    case System.cmd("ps", ["-o", "lstart=", "-p", Integer.to_string(pid)], stderr_to_stdout: true) do
      {output, 0} ->
        case String.trim(output) do
          "" -> nil
          start -> start
        end

      _gone ->
        nil
    end
  catch
    _kind, _reason -> nil
  end

  defp safe_close(port) do
    Port.close(port)
    :ok
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
