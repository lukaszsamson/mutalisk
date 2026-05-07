defmodule Mut.Worker.PersistentRunner do
  @dialyzer {:no_opaque, [apply_file_filter: 2]}

  alias Mut.Worker.PersistentRunner.Diag
  alias Mut.Worker.PersistentRunner.Reset

  @moduledoc """
  Bootstraps a persistent ExUnit BEAM and serves mutant-run commands
  over stdin/stdout.

  Runs inside the SPAWNED worker BEAM, not the host. The host side is
  `Mut.Worker.Persistent`; together they implement the V17 contract.

  ## Protocol

  After loading ExUnit and the user's test files, the runner writes
  one line to stdout:

      MUT_READY

  The host then writes one of these commands per line on stdin:

      RUN <mutant_id>
      RUN <mutant_id> <file1>\\t<file2>...
      STOP

  For each `RUN`, the runner:

  1. Sets `:persistent_term` to flip the active mutant.
  2. If the optional file list is non-empty, configures ExUnit's
     `only_test_ids` to the intersection of `{module, test_name}`
     pairs whose `tags.file` matches one of the supplied paths.
     Empty list means "run every loaded test module".
  3. Calls `ExUnit.run/0`.
  4. Resets leak vectors (V17) before returning.
  5. Writes one final line summarising the run:

         MUT_RESULT killed|survived <duration_us>
  """

  @ready_marker "MUT_READY"
  @result_marker "MUT_RESULT"
  @stop_command "STOP"

  @spec run([Path.t()], keyword) :: :ok | no_return
  def run(test_files, opts \\ []) when is_list(test_files) do
    boot_started_us = Diag.now_us()

    {:ok, _} = Application.ensure_all_started(:logger)
    {:ok, _} = Application.ensure_all_started(:ex_unit)

    # Start the project's OTP applications. Without this, Application.start/2
    # callbacks never fire — so any resources they create (named ETS tables,
    # registered processes, etc.) are missing. plug_crypto's
    # Plug.Crypto.Application creates the named `Plug.Crypto.Keys` ETS table
    # this way; tests calling sign/encrypt then crash with :badarg, producing
    # spurious kills versus the mix worker (which mix-test starts apps for).
    {app_startup_us, app_startup_count} = time_app_startup()

    # max_failures: 1 mirrors `mix test --max-failures 1` that the
    # mix-spawn worker passes. Without this, ExUnit runs every
    # selected test even after one fails — and some Decimal mutants
    # (~30 of them) cause an early test to fail AND a later test to
    # infinite-loop. mix would have aborted after the first failure;
    # persistent (without max_failures) ran the loop to the 60s
    # deadline and reported Timeout. This was the M21 leak vector.
    ExUnit.start(autorun: false, formatters: [Mut.Worker.Formatter], max_failures: 1)

    test_helper = Keyword.get(opts, :test_helper)

    {test_load_count, test_load_us} =
      Diag.time(fn -> require_files(test_helper, test_files) end)

    ExUnit.configure(formatters: [Mut.Worker.Formatter])

    # Capture ExUnit.Server state with all test modules loaded.
    # ExUnit.run/0 drains `sync_modules`/`async_modules`; we reset
    # the server to this snapshot before every subsequent run.
    #
    # Leak baselines must be captured before the first mutant runs.
    # Otherwise state created by mutant 1 becomes the "clean" baseline
    # for every later mutant, which can produce spurious kills.
    snapshot = %{
      ex_unit: capture_server_state(),
      file_index: build_file_index(),
      leak_baseline: capture_leak_baseline()
    }

    {memory_total, memory_processes} = Diag.memory_snapshot()
    boot_us = Diag.elapsed_us(boot_started_us)

    Diag.emit_boot(%{
      boot_us: boot_us,
      app_startup_us: app_startup_us,
      app_startup_count: app_startup_count,
      test_load_us: test_load_us,
      test_load_count: test_load_count,
      memory_total: memory_total,
      memory_processes: memory_processes
    })

    write_marker(@ready_marker)
    loop(snapshot)
  end

  defp time_app_startup do
    started = Diag.now_us()
    count = start_project_apps()
    {Diag.elapsed_us(started), count}
  end

  defp require_files(test_helper, test_files) do
    helper_count = require_one(test_helper)
    Enum.reduce(test_files, helper_count, fn file, count -> count + require_one(file) end)
  end

  defp require_one(nil), do: 0

  defp require_one(file) do
    if File.exists?(file) do
      Code.require_file(file)
      1
    else
      0
    end
  end

  defp loop(snapshot) do
    case IO.read(:stdio, :line) do
      :eof ->
        :ok

      {:error, _reason} ->
        :ok

      line ->
        line
        |> String.trim_trailing("\n")
        |> handle_command(snapshot)
    end
  end

  defp handle_command(@stop_command, _snapshot), do: :ok

  defp handle_command("RUN " <> rest, snapshot) do
    {mutant_id, test_files} = parse_run(rest)
    new_snapshot = do_run(mutant_id, test_files, snapshot)
    loop(new_snapshot)
  rescue
    exception ->
      write_marker("#{@result_marker} error 0 #{escape(Exception.message(exception))}")
      loop(snapshot)
  end

  defp handle_command(_unrecognized, snapshot), do: loop(snapshot)

  defp parse_run(rest) do
    case String.split(rest, " ", parts: 2) do
      [mutant_id_str] ->
        {mutant_id_str |> String.trim() |> String.to_integer(), []}

      [mutant_id_str, files_blob] ->
        mutant_id = mutant_id_str |> String.trim() |> String.to_integer()
        files = files_blob |> String.trim() |> String.split("\t", trim: true)
        {mutant_id, files}
    end
  end

  defp do_run(mutant_id, test_files, snapshot) do
    started = Diag.now_us()
    diag_enabled? = Diag.enabled?()

    :persistent_term.put({Mut.Runtime, :active_mutant}, mutant_id)
    restore_server_state(snapshot.ex_unit)

    {filter, filter_us} = Diag.time(fn -> apply_file_filter(test_files, snapshot.file_index) end)

    case filter do
      :ok ->
        reset_timings = reset_leaks(snapshot, diag_enabled?)

        {%{failures: failures}, run_us} = Diag.time(fn -> ExUnit.run() end)

        elapsed_us = Diag.elapsed_us(started)

        if diag_enabled? do
          {memory_total, memory_processes} = Diag.memory_snapshot()

          Diag.emit_run(
            %{
              run_us: run_us,
              filter_us: filter_us,
              memory_total: memory_total,
              memory_processes: memory_processes
            }
            |> Map.merge(reset_timings)
          )
        end

        status = if failures == 0, do: "survived", else: "killed"
        write_marker("#{@result_marker} #{status} #{elapsed_us}")

      {:error, {:filter_miss, missing}} ->
        elapsed_us = Diag.elapsed_us(started)

        # Tell the host this mutant could not be run with the
        # requested file selection. The host catches this and reruns
        # the mutant via the mix-spawn worker with the same selection.
        # Without this the runner would silently fall back to "run
        # every loaded test" and produce spurious kills.
        write_marker("#{@result_marker} filter_miss #{elapsed_us} #{escape(inspect(missing))}")
    end

    snapshot
  end

  @doc false
  @spec apply_file_filter([Path.t()], %{Path.t() => [{module(), atom()}]}) ::
          :ok | {:error, {:filter_miss, [Path.t()]}}
  def apply_file_filter(files, index) do
    # Always restore "no filter" first so a previous mutant's filter
    # doesn't bleed across runs (defensive: ExUnit holds the config
    # in :persistent_term).
    ExUnit.configure(only_test_ids: nil)

    case files do
      [] ->
        :ok

      files when is_list(files) ->
        {test_ids, missing_files} = lookup_files_in_index(files, index)

        cond do
          missing_files != [] ->
            # F1 fix: a non-empty selection that resolves to ZERO loaded
            # tests for any of its files used to silently fall through
            # to "no filter" (run everything). On plug_crypto-class
            # targets that widened persistent's effective test set
            # versus mix and produced spurious kills. Surface the miss
            # so the host can rerun the mutant via the mix-spawn worker
            # with the same selected files.
            {:error, {:filter_miss, missing_files}}

          MapSet.size(test_ids) == 0 ->
            # All requested files mapped to zero test ids (no tests in
            # those files at all). Treat the same as "filter miss" so
            # the host doesn't fall back to running everything.
            {:error, {:filter_miss, files}}

          true ->
            ExUnit.configure(only_test_ids: test_ids)
            :ok
        end
    end
  end

  defp lookup_files_in_index(files, index) do
    Enum.reduce(files, {MapSet.new(), []}, fn file, {acc_ids, missing} ->
      case index_lookup(index, file) do
        [] ->
          {acc_ids, [file | missing]}

        ids ->
          {Enum.reduce(ids, acc_ids, &MapSet.put(&2, &1)), missing}
      end
    end)
    |> then(fn {ids, missing} -> {ids, Enum.reverse(missing)} end)
  end

  defp index_lookup(index, file) do
    expanded = Path.expand(file)

    Map.get(index, expanded, []) ++ Map.get(index, file, [])
  end

  @doc false
  @spec build_file_index() :: %{Path.t() => [{module(), atom()}]}
  def build_file_index do
    case Process.whereis(ExUnit.Server) do
      nil ->
        %{}

      _pid ->
        state = :sys.get_state(ExUnit.Server)
        sync = state.sync_modules || []
        # Async modules are stored as `{queue, list}`; flatten safely.
        async = collect_async(state.async_modules)

        (sync ++ async)
        |> Enum.flat_map(&module_test_ids/1)
        |> Enum.group_by(fn {file, _module, _name} -> Path.expand(file) end, fn
          {_file, module, name} -> {module, name}
        end)
    end
  rescue
    _ -> %{}
  catch
    _, _ -> %{}
  end

  defp collect_async({prefix, suffix}) when is_list(prefix) and is_list(suffix),
    do: prefix ++ suffix

  defp collect_async(list) when is_list(list), do: list
  defp collect_async(_), do: []

  defp module_test_ids({module, _meta}) do
    with {:module, _} <- Code.ensure_loaded(module),
         true <- function_exported?(module, :__ex_unit__, 0) do
      tests = module.__ex_unit__().tests
      Enum.flat_map(tests, &test_id_for_module(module, &1))
    else
      _ -> []
    end
  rescue
    _ -> []
  end

  defp test_id_for_module(module, test) do
    case Map.get(test.tags, :file) do
      nil -> []
      file -> [{file, module, test.name}]
    end
  end

  # Discover and start every project app present on the code path, except
  # OTP/system apps and ex_unit/logger (already started). Failures are
  # tolerated: an app that can't start is logged but not fatal — the
  # mutant run will simply fail consistently with mix.
  @system_apps_for_start ~w(kernel stdlib elixir compiler asn1 crypto ssl public_key
                            sasl runtime_tools mix iex hex logger inets ex_unit
                            syntax_tools tools jason)a

  defp start_project_apps do
    discover_project_apps()
    |> Enum.reject(&(&1 in @system_apps_for_start))
    |> Enum.reduce(0, fn app, started -> started + start_one_app(app) end)
  end

  defp start_one_app(app) do
    _ = Application.load(app)

    case Application.ensure_all_started(app) do
      {:ok, list} when is_list(list) -> length(list)
      _ -> 0
    end
  end

  # Limit discovery to apps in the schema build path (added by the host via
  # `-pa _build/mut_schema/lib/*/ebin`). That keeps OS/OTP apps that happen
  # to live on the default code path (os_mon, et al) from getting started
  # spuriously.
  defp discover_project_apps do
    :code.get_path()
    |> Enum.map(&List.to_string/1)
    |> Enum.filter(&String.contains?(&1, "_build/mut_schema/"))
    |> Enum.flat_map(fn path -> path |> Path.join("*.app") |> Path.wildcard() end)
    |> Enum.map(&(&1 |> Path.basename(".app") |> String.to_atom()))
    |> Enum.uniq()
  end

  defp capture_leak_baseline do
    %{
      app_env: Reset.capture_app_env(),
      ets_tables: Reset.capture_ets_tables(),
      registered: Reset.capture_registered(),
      persistent_terms: Reset.capture_persistent_terms()
    }
  end

  defp capture_server_state do
    case Process.whereis(ExUnit.Server) do
      nil -> nil
      _pid -> :sys.get_state(ExUnit.Server)
    end
  end

  defp restore_server_state(nil), do: :ok

  defp restore_server_state(snapshot) do
    case Process.whereis(ExUnit.Server) do
      nil -> :ok
      _pid -> :sys.replace_state(ExUnit.Server, fn _ -> snapshot end)
    end

    :ok
  end

  ## --- Leak-vector reset ---------------------------------------------------

  # Returns a map of per-vector microsecond timings when diag_enabled? is
  # true, an empty map otherwise. The map is shaped to merge directly
  # into the per-mutant metrics payload.
  defp reset_leaks(%{leak_baseline: %{} = baseline}, diag_enabled?) do
    if diag_enabled? do
      {_, app_env_us} = Diag.time(fn -> Reset.reset_app_env(baseline.app_env) end)
      {_, ets_us} = Diag.time(fn -> Reset.reset_ets_tables(baseline.ets_tables) end)
      {_, processes_us} = Diag.time(fn -> Reset.reset_registered(baseline.registered) end)

      {_, persistent_term_us} =
        Diag.time(fn ->
          Reset.reset_persistent_terms(baseline.persistent_terms, [
            {Mut.Runtime, :active_mutant}
          ])
        end)

      {_, on_exit_us} = Diag.time(fn -> Reset.clear_on_exit_handler() end)

      %{
        reset_app_env_us: app_env_us,
        reset_ets_us: ets_us,
        reset_processes_us: processes_us,
        reset_persistent_term_us: persistent_term_us,
        reset_on_exit_us: on_exit_us
      }
    else
      Reset.reset_app_env(baseline.app_env)
      Reset.reset_ets_tables(baseline.ets_tables)
      Reset.reset_registered(baseline.registered)
      Reset.reset_persistent_terms(baseline.persistent_terms, [{Mut.Runtime, :active_mutant}])
      Reset.clear_on_exit_handler()
      %{}
    end
  end

  defp escape(message) do
    message
    |> to_string()
    |> String.replace("\n", " ")
    |> String.slice(0, 200)
  end

  defp write_marker(line) do
    IO.puts(line)
  end
end
