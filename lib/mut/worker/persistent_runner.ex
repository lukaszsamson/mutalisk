defmodule Mut.Worker.PersistentRunner do
  @dialyzer {:no_opaque, [apply_file_filter: 2]}

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
    {:ok, _} = Application.ensure_all_started(:logger)
    {:ok, _} = Application.ensure_all_started(:ex_unit)

    ExUnit.start(autorun: false, formatters: [])

    if path = Keyword.get(opts, :test_helper) do
      if File.exists?(path), do: Code.require_file(path)
    end

    Enum.each(test_files, fn file ->
      if File.exists?(file), do: Code.require_file(file)
    end)

    # Capture ExUnit.Server state with all test modules loaded.
    # ExUnit.run/0 drains `sync_modules`/`async_modules`; we reset
    # the server to this snapshot before every subsequent run.
    #
    # ETS / registered-process / persistent_term snapshots are
    # captured LAZILY on first do_run, *after* ExUnit's
    # OnExitHandler / RunnerStats / async-test infra has been
    # initialised. Otherwise the diff treats those as "new" tables
    # and processes and tears them down, leaving the second run
    # unable to call ExUnit.run/0 cleanly.
    snapshot = %{
      ex_unit: capture_server_state(),
      file_index: build_file_index(),
      leak_baseline: nil
    }

    write_marker(@ready_marker)
    loop(snapshot)
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
    started = System.monotonic_time(:microsecond)

    :persistent_term.put({Mut.Runtime, :active_mutant}, mutant_id)
    restore_server_state(snapshot.ex_unit)
    apply_file_filter(test_files, snapshot.file_index)

    if snapshot.leak_baseline, do: reset_leaks(snapshot)

    %{failures: failures} = ExUnit.run()

    new_snapshot = capture_or_keep_leak_baseline(snapshot)

    elapsed_us = System.monotonic_time(:microsecond) - started

    status = if failures == 0, do: "survived", else: "killed"

    write_marker("#{@result_marker} #{status} #{elapsed_us}")
    new_snapshot
  end

  defp apply_file_filter(files, index) do
    # Always restore "no filter" first so a previous mutant's filter
    # doesn't bleed across runs (defensive: ExUnit holds the config
    # in :persistent_term).
    ExUnit.configure(only_test_ids: nil)

    case files do
      [] ->
        :ok

      files when is_list(files) ->
        test_ids =
          files
          |> Enum.flat_map(fn file ->
            Map.get(index, Path.expand(file), []) ++ Map.get(index, file, [])
          end)
          |> MapSet.new()

        if MapSet.size(test_ids) > 0 do
          ExUnit.configure(only_test_ids: test_ids)
        end

        :ok
    end
  end

  defp build_file_index do
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
        |> Enum.group_by(fn {file, _module, _name} -> file end, fn
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

  defp capture_or_keep_leak_baseline(%{leak_baseline: nil} = snapshot) do
    Map.put(snapshot, :leak_baseline, %{
      app_env: Reset.capture_app_env(),
      ets_tables: Reset.capture_ets_tables(),
      registered: Reset.capture_registered(),
      persistent_terms: Reset.capture_persistent_terms()
    })
  end

  defp capture_or_keep_leak_baseline(snapshot), do: snapshot

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

  defp reset_leaks(%{leak_baseline: %{} = baseline}) do
    Reset.reset_app_env(baseline.app_env)
    Reset.reset_ets_tables(baseline.ets_tables)
    Reset.reset_registered(baseline.registered)
    Reset.reset_persistent_terms(baseline.persistent_terms, [{Mut.Runtime, :active_mutant}])
    Reset.clear_on_exit_handler()
    :ok
  end

  defp reset_leaks(_snapshot), do: :ok

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
