defmodule Mut.Worker.Persistent do
  @moduledoc """
  Host-side controller for a persistent ExUnit worker BEAM.

  See `V17_PERSISTENT_WORKER.md` and `Mut.Worker.PersistentRunner`.
  Spawns one worker BEAM per sandbox, holds ExUnit + the user's
  test files in memory, and flips `:persistent_term` per mutant
  instead of paying mix-test boot cost on every mutant.

  ## Lifecycle

      {:ok, server} = Mut.Worker.Persistent.start_link(sandbox)
      result = Mut.Worker.Persistent.run_schema(server, mutant_id, files)
      result = Mut.Worker.Persistent.run_fallback(server, mutant_id, compile, tests)
      :ok = Mut.Worker.Persistent.stop(server)

  ## Behaviour

  - **Schema mutants** run via `run_schema/4`. The schema bytecode
    is loaded once at boot; mutant selection is a `:persistent_term`
    flip read by the runtime dispatch.
  - **Fallback mutants** run via `run_fallback/5` (M21 phase 2).
    The host has already applied the source patch to the sandbox;
    this call asks the persistent BEAM to recompile the patched
    files in-process via `Code.compile_file/1`, run ExUnit, then
    restore the originals via `:code.purge/1` + `:code.load_file/1`
    (the schema-build ebins on the runner's `-pa` provide the
    originals). No mix-spawn child process per fallback mutant.
    A compile error replies `{:compile_error, category, message}`
    and the host materialises a Result with status: :invalid; mix
    retry on a compile error would just fail the same way.
  - The `test_files` argument scopes ExUnit's `only_test_ids` to
    the tests in those files. An empty list runs every loaded test
    module.
  - On **filter miss** (selected files map to zero loaded tests),
    the server replies `:filter_miss` and the host reruns the
    mutant via the mix-spawn worker.
  - On **crash** (port exit / run timeout), the server reboots the
    BEAM in-place and replies `:crashed` (port exit) or `:timeout`
    (host deadline expired) for the failing mutant. The host
    reruns that mutant via mix-spawn but subsequent mutants on the
    same sandbox stay on persistent. If the restart itself fails,
    the GenServer stops with `:worker_crashed` and the host falls
    back to mix-spawn for every remaining mutant on this sandbox.
  """

  use GenServer

  alias Mut.Sandbox
  alias Mut.Worker.Formatter
  alias Mut.Worker.PersistentRunner.Diag
  alias Mut.Worker.Result

  @ready_marker "MUT_READY"
  @result_marker "MUT_RESULT"
  @default_boot_timeout_ms 30_000
  @default_run_timeout_ms 60_000

  @type server :: GenServer.server()

  @spec start_link(Sandbox.t(), keyword) :: GenServer.on_start()
  def start_link(%Sandbox{} = sandbox, opts \\ []) do
    # Intentionally `GenServer.start/3` (not `start_link`). When the
    # persistent worker BEAM crashes, the GenServer stops with
    # :worker_crashed. We want that crash to surface only via
    # `Persistent.run_schema/4`'s GenServer.call exit (which the host
    # catches and routes to mix) — NOT to propagate as a linked-exit
    # signal that takes down the host's Task.async_stream worker.
    GenServer.start(__MODULE__, {sandbox, opts})
  end

  @spec run_schema(server, non_neg_integer(), [Path.t()], keyword) ::
          Result.t() | :filter_miss | :crashed | :timeout
  def run_schema(server, mutant_id, test_files, opts \\ [])
      when is_integer(mutant_id) and mutant_id >= 0 and is_list(test_files) and is_list(opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_run_timeout_ms)
    # GenServer.call timeout is :infinity because the in-handle_call
    # wait_for_result uses a PER-MESSAGE (relative) timeout — a slow
    # but data-producing worker can legitimately exceed timeout_ms of
    # absolute wall-clock. The handle_call's own deadline is the
    # authority on when to declare timeout/crash; we never want
    # GenServer.call to fire its own caller-side timeout and crash
    # the calling Task with :exit.
    GenServer.call(server, {:run_schema, mutant_id, test_files, timeout_ms}, :infinity)
  end

  @doc """
  M21 in-process fallback recompile. The host has already applied the
  source patch to the sandbox (via `Mut.FallbackPatch.apply/2`). This
  call asks the persistent BEAM to recompile the patched files
  in-process, run ExUnit, and restore the originals from
  `_build/mut_schema/lib/<app>/ebin/`.

  Replies:

    * `Result.t()` — the run completed (status: :killed | :survived).
    * `{:compile_error, category, message}` — patch did not compile.
      Category mirrors `Mut.Recompile.error_category/0`. Caller
      materialises a `Result{status: :invalid, recompile_category: cat}`.
    * `:filter_miss` — selected test files don't map to any loaded
      tests. Caller routes via mix-spawn fallback.
    * `:timeout` / `:crashed` — host-side deadline expired or the
      worker BEAM died. Caller routes via mix-spawn fallback.
  """
  @spec run_fallback(server, non_neg_integer(), [Path.t()], [Path.t()], keyword) ::
          Result.t()
          | :filter_miss
          | :crashed
          | :timeout
          | {:compile_error, atom(), String.t()}
  def run_fallback(server, mutant_id, compile_files, test_files, opts \\ [])
      when is_integer(mutant_id) and mutant_id >= 0 and is_list(compile_files) and
             is_list(test_files) and is_list(opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_run_timeout_ms)

    GenServer.call(
      server,
      {:run_fallback, mutant_id, compile_files, test_files, timeout_ms},
      :infinity
    )
  end

  @spec stop(server, timeout()) :: :ok
  def stop(server, timeout \\ 5_000) do
    GenServer.stop(server, :normal, timeout)
  end

  @doc """
  Returns this worker's accumulated diagnostic metrics. Always safe
  to call; returns the empty/zero-shape when no runs have happened
  yet. The host calls this at run end on every Persistent server it
  started, then folds the per-worker metrics into `Mut.Metrics`.
  """
  @spec metrics(server) :: %{
          boot_ms: non_neg_integer(),
          boot_metrics: map() | nil,
          run_metrics: [map()],
          crash_count: non_neg_integer(),
          restart_count: non_neg_integer(),
          filter_miss_count: non_neg_integer(),
          mix_fallback_count: non_neg_integer(),
          memory_peak_total: non_neg_integer(),
          memory_peak_processes: non_neg_integer()
        }
  def metrics(server) do
    GenServer.call(server, :metrics, 5_000)
  catch
    # If the server is dead, return whatever shape callers expect so
    # the host's metrics fold doesn't blow up. The host already
    # tracked the crash via run_schema_via_persistent's :exit catch.
    :exit, _ ->
      %{
        boot_ms: 0,
        boot_metrics: nil,
        run_metrics: [],
        crash_count: 0,
        restart_count: 0,
        filter_miss_count: 0,
        mix_fallback_count: 0,
        memory_peak_total: 0,
        memory_peak_processes: 0
      }
  end

  ## GenServer

  @impl GenServer
  def init({%Sandbox{} = sandbox, opts}) do
    Process.flag(:trap_exit, true)

    case boot_port(sandbox, opts) do
      {:ok, port, leftover, boot_ms, boot_metrics} ->
        {:ok,
         %{
           port: port,
           sandbox: sandbox,
           leftover: leftover,
           opts: opts,
           boot_ms: boot_ms,
           boot_metrics: boot_metrics,
           run_metrics: [],
           crash_count: 0,
           restart_count: 0,
           filter_miss_count: 0,
           mix_fallback_count: 0,
           memory_peak_total: peak_total(boot_metrics, 0),
           memory_peak_processes: peak_processes(boot_metrics, 0)
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call(:metrics, _from, state) do
    {:reply, metrics_view(state), state}
  end

  def handle_call(
        {:run_fallback, mutant_id, compile_files, test_files, timeout_ms},
        _from,
        state
      ) do
    started = System.monotonic_time(:millisecond)
    compile_blob = encode_relative(compile_files)
    test_blob = encode_relative(test_files)
    Port.command(state.port, "RUN_FALLBACK #{mutant_id} #{compile_blob}|#{test_blob}\n")
    handle_run_reply(state, started, timeout_ms)
  end

  def handle_call({:run_schema, mutant_id, test_files, timeout_ms}, _from, state) do
    started = System.monotonic_time(:millisecond)
    files_blob = encode_files(test_files, state.sandbox)
    Port.command(state.port, "RUN #{mutant_id}#{files_blob}\n")
    handle_run_reply(state, started, timeout_ms)
  end

  # Shared run-reply handler for both :run_schema and :run_fallback.
  # The wire-protocol reply layouts match — both end in MUT_RESULT
  # with status killed/survived/filter_miss/error/compile_error.
  defp handle_run_reply(state, started, timeout_ms) do
    case wait_for_result(state.port, state.leftover, timeout_ms) do
      {:filter_miss, _leftover, run_metrics} ->
        # Filter miss is recoverable: the worker BEAM is still
        # healthy, but the host needs to rerun this mutant via mix
        # because the persistent runner could not resolve the
        # selected files to any loaded test ids. Reply with
        # :filter_miss; the caller treats it the same as a crash
        # exit and re-routes via mix without tearing the BEAM down.
        state =
          state
          |> Map.update!(:filter_miss_count, &(&1 + 1))
          |> Map.update!(:mix_fallback_count, &(&1 + 1))
          |> record_run_metrics(run_metrics)

        {:reply, :filter_miss, %{state | leftover: ""}}

      {:ok, result, leftover, run_metrics} ->
        duration_ms = System.monotonic_time(:millisecond) - started
        state = record_run_metrics(state, run_metrics)
        {:reply, %{result | duration_ms: duration_ms}, %{state | leftover: leftover}}

      {:compile_error, category, message, _duration_ms} ->
        # M21 in-process fallback: patch did not compile. The
        # persistent BEAM is still healthy (we reset modules in the
        # `after` clause regardless). Reply with the category +
        # message so the host materialises Result{status: :invalid,
        # recompile_category: category}. Mix-retry would just fail
        # with the same compile error, so don't bother.
        {:reply, {:compile_error, category, message}, %{state | leftover: ""}}

      {:error, kind, _leftover} when kind in [:timeout, :crashed] ->
        # F4 auto-restart + M20 timeout/crash split:
        # - :timeout — host deadline expired. The persistent BEAM is
        #   restarted in place so this sandbox's NEXT mutant stays on
        #   persistent; the current mutant is replied as :timeout. The
        #   host still routes to mix-spawn for byte-identity (M20
        #   Phase A found ~30 Decimal mutants where persistent stalls
        #   but mix kills them cleanly).
        # - :crashed — port exited mid-run. Same restart-in-place; host
        #   routes to mix-spawn.
        # If the restart itself fails the GenServer stops with
        # :worker_crashed; the host's :exit catch handles the rest.
        kill_port(state.port)
        reply = if kind == :timeout, do: :timeout, else: :crashed

        state =
          state
          |> Map.update!(:crash_count, &(&1 + 1))
          |> Map.update!(:mix_fallback_count, &(&1 + 1))

        case boot_port(state.sandbox, state.opts) do
          {:ok, new_port, leftover, _boot_ms, boot_metrics} ->
            state =
              state
              |> Map.update!(:restart_count, &(&1 + 1))
              |> bump_memory_peaks(boot_metrics)

            {:reply, reply, %{state | port: new_port, leftover: leftover}}

          {:error, _reason} ->
            {:stop, :worker_crashed, reply, %{state | leftover: ""}}
        end
    end
  end

  @impl GenServer
  def terminate(_reason, %{port: port}) when is_port(port) do
    if Port.info(port) != nil do
      _ = Port.command(port, "STOP\n")
      kill_port(port)
    end

    :ok
  end

  def terminate(_reason, _state), do: :ok

  ## Internals

  defp boot_port(sandbox, opts) do
    boot_timeout = Keyword.get(opts, :boot_timeout_ms, @default_boot_timeout_ms)
    boot_started_ms = System.monotonic_time(:millisecond)

    case open_port(sandbox, opts) do
      {:ok, port, leftover} ->
        case wait_for_ready(port, leftover, boot_timeout) do
          {:ok, leftover, boot_metrics} ->
            boot_ms = System.monotonic_time(:millisecond) - boot_started_ms
            {:ok, port, leftover, boot_ms, boot_metrics}

          {:error, reason} ->
            kill_port(port)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    # `Port.open` raises ArgumentError / ErlangError when the
    # executable can't be spawned (missing file, EACCES). Treat any
    # such failure during auto-restart as a non-recoverable boot
    # failure so the GenServer stops and the host falls back to mix.
    error -> {:error, {:port_open_failed, Exception.message(error)}}
  end

  defp open_port(sandbox, opts) do
    elixir = Keyword.get(opts, :elixir_path) || System.find_executable("elixir")

    if elixir == nil do
      {:error, :elixir_not_found}
    else
      args = elixir_args(sandbox, opts)
      env = port_env(opts)

      port =
        Port.open({:spawn_executable, elixir}, [
          {:args, args},
          {:cd, sandbox.path},
          {:env, env},
          :binary,
          :exit_status,
          :use_stdio,
          :hide,
          {:line, 65_536}
        ])

      {:ok, port, ""}
    end
  end

  defp elixir_args(sandbox, opts) do
    pa_flags =
      sandbox.path
      |> Path.join("_build/mut_schema/lib/*/ebin")
      |> Path.wildcard()
      |> Enum.flat_map(fn ebin ->
        relative = Path.relative_to(ebin, sandbox.path)
        ["-pa", relative]
      end)

    test_files = discover_test_files(sandbox, opts)
    test_helper = test_helper_path(sandbox, opts)

    eval =
      "Mut.Worker.PersistentRunner.run(#{inspect(test_files)}, " <>
        inspect_helper_opt(test_helper) <> ")"

    # No `--no-halt`: when the runner's loop exits (STOP command or
    # stdin EOF), the BEAM should terminate naturally. With --no-halt
    # the worker BEAM survives port closure forever and accumulates as
    # an orphan, which breaks subsequent test runs that read from
    # stale processes.
    pa_flags ++ ["--eval", eval]
  end

  defp discover_test_files(sandbox, opts) do
    case Keyword.get(opts, :test_files) do
      nil ->
        sandbox.path
        |> Path.join("test/**/*_test.exs")
        |> Path.wildcard()
        |> Enum.map(&Path.relative_to(&1, sandbox.path))
        |> Enum.sort()

      files when is_list(files) ->
        files
    end
  end

  defp test_helper_path(sandbox, opts) do
    case Keyword.get(opts, :test_helper) do
      nil ->
        candidate = Path.join(sandbox.path, "test/test_helper.exs")

        if File.exists?(candidate) do
          Path.relative_to(candidate, sandbox.path)
        else
          nil
        end

      path ->
        path
    end
  end

  defp inspect_helper_opt(nil), do: "[]"
  defp inspect_helper_opt(path), do: "[test_helper: #{inspect(path)}]"

  defp forward_env(key) do
    case System.get_env(key) do
      nil -> nil
      value -> {key, value}
    end
  end

  defp port_env(opts) do
    base = [
      {"MIX_ENV", "test"},
      {"MIX_BUILD_PATH", "_build/mut_schema"},
      {"MIX_DEPS_PATH", "_build/mut_schema/deps"},
      {"MUTALISK_ROLE", "persistent"},
      {"MUTALISK_PATH", Path.expand(File.cwd!())},
      {"MUT_ACTIVE", "0"}
    ]

    forwarded =
      [forward_env("MUT_PERSISTENT_DIAG")]
      |> Enum.reject(&is_nil/1)

    extra = Keyword.get(opts, :env, [])
    merged = base ++ forwarded ++ extra

    Enum.map(merged, fn {key, value} ->
      {String.to_charlist(key), String.to_charlist(value)}
    end)
  end

  defp wait_for_ready(port, leftover, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_ready(port, leftover, deadline, nil)
  end

  defp do_wait_for_ready(port, acc, deadline, boot_metrics) do
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, {:eol, line}}} ->
        if line == @ready_marker do
          {:ok, "", boot_metrics}
        else
          case Diag.parse_line(line) do
            {:ok, :boot, metrics} ->
              do_wait_for_ready(port, acc, deadline, metrics)

            _ ->
              do_wait_for_ready(port, acc <> line <> "\n", deadline, boot_metrics)
          end
        end

      {^port, {:data, {:noeol, partial}}} ->
        do_wait_for_ready(port, acc <> partial, deadline, boot_metrics)

      {^port, {:exit_status, code}} ->
        {:error, {:worker_exited_during_boot, code, acc}}
    after
      timeout ->
        {:error, {:worker_boot_timeout, acc}}
    end
  end

  # M21 fix: per-message timeout, mirroring `Mut.Worker.collect/3`.
  # The deadline resets every time the worker BEAM produces output
  # (any port {:data, _} or test-progress line). A test that legitimately
  # takes 60.5s but emits per-test JSONL while running survives the
  # 60s deadline as long as silence between messages stays under
  # `timeout_ms`. This matches mix-spawn's behaviour exactly and was
  # one of the M21 leak vectors: persistent's old absolute deadline
  # killed tests that mix's relative deadline kept alive.
  defp wait_for_result(port, leftover, timeout_ms) do
    do_wait_for_result(port, leftover, timeout_ms, nil)
  end

  defp do_wait_for_result(port, acc, timeout_ms, run_metrics) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        case parse_result_line(line) do
          # `:filter_miss` is a control signal, not a Result.status.
          # Surface it directly so the host's handle_run_reply can
          # route via mix-spawn without ever materialising an
          # out-of-spec Result struct.
          {:ok, :filter_miss, _duration_us} ->
            {:filter_miss, acc, run_metrics}

          {:ok, status, duration_us} ->
            duration_ms = max(div(duration_us, 1000), 0)

            result =
              %Result{
                status: status,
                duration_ms: duration_ms,
                raw_output: trim_output(acc),
                killing_test: killing_test(acc)
              }

            {:ok, result, "", run_metrics}

          {:compile_error, {duration_us, category, message}} ->
            duration_ms = max(div(duration_us, 1000), 0)
            {:compile_error, category, message, duration_ms}

          :passthrough ->
            case Diag.parse_line(line) do
              {:ok, :run, metrics} ->
                do_wait_for_result(port, acc, timeout_ms, metrics)

              _ ->
                do_wait_for_result(port, acc <> line <> "\n", timeout_ms, run_metrics)
            end
        end

      {^port, {:data, {:noeol, partial}}} ->
        do_wait_for_result(port, acc <> partial, timeout_ms, run_metrics)

      {^port, {:exit_status, _code}} ->
        {:error, :crashed, acc}
    after
      timeout_ms ->
        {:error, :timeout, acc}
    end
  end

  defp parse_result_line(@result_marker <> " " <> rest) do
    case String.split(rest, " ", parts: 2) do
      ["killed", duration_us_str] ->
        {:ok, :killed, parse_duration(duration_us_str)}

      ["survived", duration_us_str] ->
        {:ok, :survived, parse_duration(duration_us_str)}

      ["error", _rest] ->
        {:ok, :error, 0}

      ["filter_miss", _rest] ->
        # Persistent runner could not resolve the requested test
        # files to any loaded test ids. Surface as :filter_miss so
        # the host reruns this mutant via mix.
        {:ok, :filter_miss, 0}

      ["compile_error", rest] ->
        # M21 in-process fallback: source patch failed to compile.
        # Format: `<duration_us> <category> <message>`. Surface the
        # category + message so the host can build a Result with
        # status: :invalid + recompile_category set.
        {:compile_error, parse_compile_error(rest)}

      _other ->
        :passthrough
    end
  end

  defp parse_result_line(_other), do: :passthrough

  defp parse_compile_error(rest) do
    case String.split(rest, " ", parts: 3) do
      [duration_us_str, category, message] ->
        {parse_duration(duration_us_str), parse_category(category), message}

      [duration_us_str, category] ->
        {parse_duration(duration_us_str), parse_category(category), ""}

      _ ->
        {0, :unknown, ""}
    end
  end

  defp parse_category("compile_error"), do: :compile_error
  defp parse_category("dep_path_error"), do: :dep_path_error
  defp parse_category(_), do: :unknown

  defp killing_test(output) do
    case Formatter.parse_output(output) do
      %{tests: tests} ->
        tests
        |> Enum.find(&(&1["status"] == "failed"))
        |> case do
          nil -> nil
          test -> "#{test["module"]} #{test["test"]}"
        end

      _other ->
        nil
    end
  end

  defp encode_files([], _sandbox), do: ""

  defp encode_files(files, sandbox) when is_list(files) do
    " " <> Enum.map_join(files, "\t", &absolute_test_path(&1, sandbox))
  end

  defp absolute_test_path(file, sandbox) do
    case Path.type(file) do
      :absolute -> file
      _ -> Path.join(sandbox.path, file)
    end
  end

  # M21 in-process fallback: the runner's CWD is the sandbox path,
  # so it can read sandbox-relative paths directly. We pass relative
  # paths (no Path.join with sandbox.path) so the runner doesn't need
  # to know about the sandbox's absolute location.
  defp encode_relative([]), do: ""

  defp encode_relative(files) when is_list(files), do: Enum.join(files, "\t")

  defp parse_duration(str) do
    case Integer.parse(String.trim(str)) do
      {n, _} when n >= 0 -> n
      _ -> 0
    end
  end

  defp trim_output(output) when byte_size(output) <= 8_192, do: output

  defp trim_output(output) do
    "...[persistent worker output truncated; retaining last 8KB]...\n" <>
      binary_part(output, byte_size(output) - 8_192, 8_192)
  end

  defp kill_port(port) when is_port(port) do
    case Port.info(port) do
      nil ->
        :ok

      _info ->
        try do
          Port.close(port)
        catch
          _, _ -> :ok
        end
    end
  end

  defp kill_port(_), do: :ok

  ## --- Diagnostic accumulators ---------------------------------------------

  defp record_run_metrics(state, nil), do: state

  defp record_run_metrics(state, metrics) when is_map(metrics) do
    state
    |> Map.update!(:run_metrics, &[metrics | &1])
    |> bump_memory_peaks(metrics)
  end

  defp bump_memory_peaks(state, nil), do: state

  defp bump_memory_peaks(state, metrics) when is_map(metrics) do
    %{
      state
      | memory_peak_total: peak_total(metrics, state.memory_peak_total),
        memory_peak_processes: peak_processes(metrics, state.memory_peak_processes)
    }
  end

  defp peak_total(nil, current), do: current

  defp peak_total(%{memory_total: m}, current) when is_integer(m) and m > 0,
    do: max(m, current)

  defp peak_total(_, current), do: current

  defp peak_processes(nil, current), do: current

  defp peak_processes(%{memory_processes: m}, current) when is_integer(m) and m > 0,
    do: max(m, current)

  defp peak_processes(_, current), do: current

  defp metrics_view(state) do
    %{
      boot_ms: state.boot_ms,
      boot_metrics: state.boot_metrics,
      run_metrics: Enum.reverse(state.run_metrics),
      crash_count: state.crash_count,
      restart_count: state.restart_count,
      filter_miss_count: state.filter_miss_count,
      mix_fallback_count: state.mix_fallback_count,
      memory_peak_total: state.memory_peak_total,
      memory_peak_processes: state.memory_peak_processes
    }
  end
end
