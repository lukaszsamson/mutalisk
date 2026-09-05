defmodule Mut.ProcessTree do
  @moduledoc """
  Tree-aware OS-process termination for spawned Ports.

  A `Port.open({:spawn_executable, ...})` reports the os_pid of the **immediate**
  child. Under a version manager (asdf/mise) or a wrapper-script `mix`, that
  immediate child is a shell/launcher that forks the real `elixir` → `beam.smp`.
  Killing only the immediate pid orphans the BEAM — which, on the timeout hot
  path, is exactly the (frequently infinite-looping) mutant VM we are trying to
  reap.

  ## Why a process *group*, not a pid walk (T32)

  The pid walk (`pgrep -P`) only works while the wrapper is alive: it is the
  root the walk descends from. A non-exec shim (`mix`/`elixir` from asdf/mise,
  or any launcher that backgrounds the real work and exits) is *gone* by the
  time a timeout fires — `Port.info(port, :os_pid)` is already `nil`, the
  wrapper pid may even have been recycled, and the descendants have been
  reparented to pid 1. There is nothing left to walk from, so the mutant BEAM
  leaks.

  A process group survives its leader. Every child spawned through
  `spawn_command/2` is placed in its own group (see below), the group id is
  recorded at `Port.open/2` time by `identify/1`, and cleanup signals the whole
  group with `kill -TERM -- -<pgid>` / `kill -KILL -- -<pgid>`. Reparented
  grandchildren stay in the group, so they are reaped even though their parent
  is gone.

  Group ids do **not** have the pid-recycling problem the pid path has: the
  kernel keeps a pgid reserved for as long as *any* process is still a member
  of that group, so a pgid can only be reused once the group we care about is
  completely empty — and signalling an empty group is a plain no-op (`ESRCH`).
  A recorded pgid therefore either still names our group or names nothing at
  all; it can never name somebody else's freshly spawned process the way a
  recycled pid can. The pid path keeps its Wave-4 `{pid, start_time}`
  verification for the cases where no group id is available.

  ## The launcher

  Erlang's `Port.open/2` cannot ask for `setpgid`, so `spawn_command/2` wraps
  the executable in a tiny launcher that creates the group and then `exec`s the
  real program, keeping pid == pgid and leaving exit status, stdout/stderr fds,
  cwd and env untouched:

    * `perl -e 'setpgrp(0,0); exec {$ARGV[0]} @ARGV or exit 127;' <exe> <args>`
      (perl ships with macOS and virtually every Linux CI image), else
    * `setsid -w <exe> <args>`, else
    * no launcher at all — the executable is spawned directly and cleanup falls
      back to the `pgrep -P` descendant walk.

  Detection runs once per VM and is cached; each candidate is *probed* (it must
  round-trip a known exit status) so a perl without `setpgrp` or a `setsid`
  without `-w` is rejected rather than silently breaking exit statuses.

  Even with no launcher a group kill is still used when the OS gave the child
  its own group anyway (recent OTP `erl_child_setup` calls `setpgid`); that is
  exactly the `pgid == os_pid` check in `identify/1`.

  Shared by `Mut.Worker` (timeout path) and `Mut.ChildProcess` (recompile path)
  so the two cannot drift — historically only `ChildProcess` tree-killed, and
  `Worker` leaked the BEAM on managed installs (see review).
  """

  @launcher_key {__MODULE__, :launcher}
  @own_pgid_key {__MODULE__, :own_pgid}

  # setpgrp(0,0) puts *this* process in a new group whose id is its own pid;
  # the indirect-object `exec {$ARGV[0]} @ARGV` form never goes through a
  # shell, so argv is passed through verbatim.
  @perl_script "setpgrp(0,0); exec {$ARGV[0]} @ARGV or exit 127;"

  @typedoc """
  Identity snapshot of a port's immediate child: its os pid, its process start
  time (pid-recycling guard for the pid path) and its process-group id, when
  the child is that group's leader.
  """
  @type identity :: %{
          os_pid: non_neg_integer(),
          start_time: String.t() | nil,
          pgid: non_neg_integer() | nil
        }

  @typedoc "Which launcher `spawn_command/2` wraps spawned executables in."
  @type launcher :: {:perl, String.t()} | {:setsid, String.t()} | :none

  @doc """
  Build the `{executable, args}` pair to hand to
  `Port.open({:spawn_executable, executable}, [{:args, args}, ...])` so the
  child lands in its own process group.

  Falls back to `{executable, args}` unchanged when no launcher is available.
  """
  @spec spawn_command(String.t(), [String.t()]) :: {String.t(), [String.t()]}
  def spawn_command(executable, args) when is_binary(executable) and is_list(args) do
    case launcher() do
      {:perl, perl} -> {perl, ["-e", @perl_script, executable | args]}
      {:setsid, setsid} -> {setsid, ["-w", executable | args]}
      :none -> {executable, args}
    end
  end

  @doc """
  The launcher used to create a process group for spawned children, detected
  once per VM and cached.
  """
  @spec launcher() :: launcher()
  def launcher do
    case :persistent_term.get(@launcher_key, :undetected) do
      :undetected ->
        detected = detect_launcher()
        :persistent_term.put(@launcher_key, detected)
        detected

      cached ->
        cached
    end
  end

  defp detect_launcher do
    # Modern OTP (`erl_child_setup`) already places every port child in its
    # own process group, in which case the launcher only adds ~3 ms per spawn
    # and a `perl` dependency for nothing. Probe a plain spawn first.
    if plain_spawn_leads_group?(), do: :none, else: detect_wrapper_launcher()
  end

  defp plain_spawn_leads_group? do
    sh = System.find_executable("sh")

    port =
      Port.open({:spawn_executable, sh}, [
        :binary,
        :exit_status,
        args: ["-c", "ps -o pgid= -p $$"]
      ])

    {:os_pid, pid} = Port.info(port, :os_pid)
    collect_probe(port, "") == Integer.to_string(pid)
  catch
    _kind, _reason -> false
  end

  defp collect_probe(port, acc) do
    receive do
      {^port, {:data, data}} -> collect_probe(port, acc <> data)
      {^port, {:exit_status, _}} -> String.trim(acc)
    after
      5_000 -> ""
    end
  end

  defp detect_wrapper_launcher do
    Enum.find_value(
      [
        {:perl, "perl", fn _perl -> ["-e", @perl_script, "/bin/sh", "-c", "exit 42"] end},
        {:setsid, "setsid", fn _setsid -> ["-w", "/bin/sh", "-c", "exit 42"] end}
      ],
      :none,
      fn {name, executable, probe_args} ->
        with path when is_binary(path) <- System.find_executable(executable),
             true <- probe(path, probe_args.(path)) do
          {name, path}
        else
          _unusable -> false
        end
      end
    )
  end

  # A launcher is only usable if it round-trips a known exit status: that
  # proves it exec'd the target (rather than forking or failing) AND that the
  # child's status still reaches us, which `:exit_status` callers depend on.
  defp probe(path, args) do
    case System.cmd(path, args, stderr_to_stdout: true) do
      {_output, 42} -> true
      _unusable -> false
    end
  catch
    _kind, _reason -> false
  end

  @doc """
  Close `port` and terminate its OS process tree. Best-effort: never raises
  (a closed port / already-dead pid / missing `pgrep` all degrade to `:ok`).

  `known`, when given, is the `identify/1` snapshot taken right after
  `Port.open/2`. Its `:pgid` is the primary handle: it stays valid after the
  immediate child has exited, which is exactly the T32 case (a non-exec
  asdf/mise-style wrapper exits — taking the port's os_pid with it — while its
  reparented `beam.smp` descendant runs on).

  When no group id is available the snapshot's `:os_pid` is used instead, but
  only after re-checking its recorded process start time, since a reaped pid
  may have been recycled.
  """
  @spec kill_port(port(), identity() | {non_neg_integer(), String.t()} | non_neg_integer() | nil) ::
          :ok
  def kill_port(port, known \\ nil) do
    known = normalize(known)

    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} when is_integer(pid) -> pid
        _unknown -> verified_known_pid(known)
      end

    pgid = killable_pgid(known)

    # Port.close/1 raises if the port already auto-closed (e.g. its
    # :exit_status was already delivered) — that must NOT skip the
    # process-tree kill below, or `known_os_pid` cleanup (the whole point of
    # T32) would be defeated by the very close call meant to precede it.
    safe_close(port)

    # Both mechanisms, not either/or: a descendant that re-groups itself
    # (`setsid`/`setpgid` — and OTP's own `erl_child_setup` does exactly that
    # for every Port the mutant's tests spawn) leaves our group, so the
    # `pgrep -P` walk from the still-verifiable leader is what reaches it;
    # conversely the group kill is what reaches reparented descendants once
    # the leader is gone. Each is best-effort and idempotent.
    if is_integer(pgid), do: kill_process_group(pgid)
    if is_integer(os_pid), do: kill_process_tree(os_pid)
    :ok
  catch
    _kind, _reason -> :ok
  end

  @doc """
  Snapshot the identity of `port`'s immediate child, or `nil` when the port has
  no os_pid (already gone) or `ps` cannot report it. Take it right after
  `Port.open/2` and hand it to `kill_port/2`.

  `:pgid` is only filled in when the child *leads* its group (`pgid == pid`).
  Otherwise the group is one we did not create — the BEAM's own group, or a
  group shared with sibling ports — and signalling it would take down
  unrelated processes (including this VM).
  """
  @spec identify(port()) :: identity() | nil
  def identify(port) do
    with {:os_pid, pid} when is_integer(pid) <- Port.info(port, :os_pid),
         {pgid, start} when is_binary(start) <- process_info(pid) do
      %{os_pid: pid, start_time: start, pgid: own_group_leader(pid, pgid)}
    else
      _unknown -> nil
    end
  end

  defp own_group_leader(pid, pgid) when pgid == pid and pgid > 1, do: pgid
  defp own_group_leader(_pid, _pgid), do: nil

  defp normalize(%{os_pid: pid} = identity) do
    %{
      os_pid: pid,
      start_time: Map.get(identity, :start_time),
      pgid: Map.get(identity, :pgid)
    }
  end

  # Legacy shapes: the Wave-4 `{pid, start_time}` tuple and a bare pid.
  defp normalize({pid, start}) when is_integer(pid) and is_binary(start),
    do: %{os_pid: pid, start_time: start, pgid: nil}

  defp normalize(pid) when is_integer(pid), do: %{os_pid: pid, start_time: nil, pgid: nil}
  defp normalize(_unknown), do: nil

  defp verified_known_pid(%{os_pid: pid, start_time: start})
       when is_integer(pid) and is_binary(start) do
    case process_info(pid) do
      {_pgid, ^start} -> pid
      _stale_or_gone -> nil
    end
  end

  defp verified_known_pid(_unverifiable), do: nil

  defp safe_close(port) do
    Port.close(port)
    :ok
  catch
    _kind, _reason -> :ok
  end

  # Decide whether the recorded group id may be signalled:
  #
  #   * it must exist, be a real group (> 1) and not be OUR OWN group — a
  #     `kill -- -<our pgid>` would take down this VM;
  #   * the group leader — which IS the immediate child, since `identify/1`
  #     only records a pgid when `pgid == os_pid` — must either be gone (the
  #     T32 case: the wrapper exited, its descendants live on in the group) or
  #     still be the very process we spawned, matched on its recorded start
  #     time and group. A live leader with a different start time means the pid
  #     was recycled, so the group is somebody else's;
  #   * an empty group (`pgrep -g` finds nothing) is a no-op — and, since the
  #     kernel keeps a pgid reserved while any member survives, an empty group
  #     is the only way a recorded pgid can go stale at all.
  defp killable_pgid(%{pgid: pgid} = known) when is_integer(pgid) and pgid > 1 do
    cond do
      pgid == own_pgid() -> nil
      not leader_ours_or_gone?(known) -> nil
      not group_alive?(pgid) -> nil
      true -> pgid
    end
  end

  defp killable_pgid(_no_group), do: nil

  defp leader_ours_or_gone?(%{os_pid: leader, start_time: start, pgid: pgid})
       when is_integer(leader) do
    case process_info(leader) do
      # Gone. The group can still hold its reparented descendants — this is
      # exactly what a non-exec wrapper leaves behind.
      nil -> true
      {^pgid, ^start} -> true
      _recycled_or_regrouped -> false
    end
  end

  defp leader_ours_or_gone?(_no_leader), do: false

  defp group_alive?(pgid) do
    case System.cmd("pgrep", ["-g", Integer.to_string(pgid)], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output) != ""
      _no_members -> false
    end
  catch
    _kind, _reason -> false
  end

  # The BEAM's own process group, cached: signalling it would kill this VM.
  defp own_pgid do
    case :persistent_term.get(@own_pgid_key, :undetected) do
      :undetected ->
        pgid =
          case process_info(System.pid()) do
            {pgid, _start} -> pgid
            nil -> nil
          end

        :persistent_term.put(@own_pgid_key, pgid)
        pgid

      cached ->
        cached
    end
  end

  @doc """
  Signal an entire process group: TERM, brief grace, then KILL.

  Unlike the pid walk this reaches processes that were reparented to pid 1 when
  their launcher exited, because group membership is inherited by `fork` and
  outlives the group leader.
  """
  @spec kill_process_group(non_neg_integer()) :: :ok
  def kill_process_group(pgid) when is_integer(pgid) and pgid > 1 do
    kill_group(pgid, "-TERM")
    Process.sleep(100)
    kill_group(pgid, "-KILL")
    :ok
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

  # `--` keeps the negative group id from being parsed as an option.
  defp kill_group(pgid, signal) do
    System.cmd("kill", [signal, "--", "-" <> Integer.to_string(pgid)], stderr_to_stdout: true)
  catch
    _kind, _reason -> {"", 1}
  end

  # `ps -o pgid=,lstart=` prints the group id and the process start time (to
  # the second); equal pid AND equal start time is as close to a unique process
  # identity as portable tooling gets.
  defp process_info(pid) when is_integer(pid), do: process_info(Integer.to_string(pid))

  defp process_info(pid) when is_binary(pid) do
    case System.cmd("ps", ["-o", "pgid=,lstart=", "-p", pid], stderr_to_stdout: true) do
      {output, 0} -> parse_process_info(output)
      _gone -> nil
    end
  catch
    _kind, _reason -> nil
  end

  defp parse_process_info(output) do
    with [line | _rest] <- String.split(output, "\n", trim: true),
         [pgid_field, start] <- String.split(String.trim(line), " ", parts: 2),
         {pgid, ""} <- Integer.parse(pgid_field),
         start when start != "" <- String.trim(start) do
      {pgid, start}
    else
      _unparsable -> nil
    end
  end
end
