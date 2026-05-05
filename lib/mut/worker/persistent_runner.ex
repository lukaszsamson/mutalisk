defmodule Mut.Worker.PersistentRunner do
  alias Mut.Worker.PersistentRunner.Reset

  @moduledoc """
  Bootstraps a persistent ExUnit BEAM and serves mutant-run commands
  over stdin/stdout.

  Runs inside the SPAWNED worker BEAM, not the host. The host side is
  `Mut.Worker.Persistent`; together they implement the V17 contract.

  ## Protocol (M19 step 1: minimal)

  After loading ExUnit and the user's test files, the runner writes
  one line to stdout:

      MUT_READY

  The host then writes one of these commands per line on stdin:

      RUN <mutant_id>
      STOP

  For each `RUN`, the runner sets `:persistent_term` to flip the
  active mutant, calls `ExUnit.run/0` (running every loaded test
  module — file-level filtering arrives in step 3), and writes one
  final line summarising the run:

      MUT_RESULT killed|survived <duration_us>

  Step 1 does not attribute killing tests; a placeholder of `-` is
  used. Step 2 adds reset hooks; step 3 adds the `only_test_ids`
  filter so we only run selected test files per mutant.
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
      app_env: Reset.capture_app_env(),
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
    mutant_id = rest |> String.trim() |> String.to_integer()
    new_snapshot = do_run(mutant_id, snapshot)
    loop(new_snapshot)
  rescue
    exception ->
      write_marker("#{@result_marker} error 0 #{escape(Exception.message(exception))}")
      loop(snapshot)
  end

  defp handle_command(_unrecognized, snapshot), do: loop(snapshot)

  defp do_run(mutant_id, snapshot) do
    started = System.monotonic_time(:microsecond)

    :persistent_term.put({Mut.Runtime, :active_mutant}, mutant_id)
    restore_server_state(snapshot.ex_unit)

    if snapshot.leak_baseline, do: reset_leaks(snapshot)

    %{failures: failures} = ExUnit.run()

    new_snapshot = capture_or_keep_leak_baseline(snapshot)

    elapsed_us = System.monotonic_time(:microsecond) - started

    status = if failures == 0, do: "survived", else: "killed"

    write_marker("#{@result_marker} #{status} #{elapsed_us}")
    new_snapshot
  end

  defp capture_or_keep_leak_baseline(%{leak_baseline: nil} = snapshot) do
    Map.put(snapshot, :leak_baseline, %{
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

  defp reset_leaks(%{leak_baseline: %{} = baseline} = snapshot) do
    Reset.reset_app_env(snapshot.app_env)
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
