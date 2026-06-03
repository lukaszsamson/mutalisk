defmodule Mix.Tasks.Mut.TestSchema do
  @moduledoc false
  use Mix.Task

  @dialyzer {:no_opaque, run: 1}

  alias Mut.Reporter.StrykerJson
  alias Mut.Worker.Result

  @shortdoc "Runs schema worker integration against demo_app"

  @fixture_root Path.expand("test/fixtures/demo_app")
  @fixture_test_paths [Path.join(@fixture_root, "test")]
  @concurrency 1
  @timeout_ms 15_000
  @m8_baseline_ms 9_300

  # Expected outcomes are grounded in test/fixtures/demo_app/test assertions.
  @expectations [
    %{stable_id: "14966a08023e637a7349711c44b348b3", expected: :killed, note: "arith + -> *"},
    %{stable_id: "f19d8b683235e84ef28fb8d9d139d852", expected: :killed, note: "arith + -> -"},
    %{stable_id: "2c610211a71402b0d80a5f05e85b09ef", expected: :killed, note: "arith - -> +"},
    %{stable_id: "8c6aca74d878982d0c2bf76c5c3df9a3", expected: :killed, note: "arith * -> +"},
    %{stable_id: "139acf2b882c3cdfa8be790efda87030", expected: :killed, note: "arith * -> /"},
    %{stable_id: "ead0057386314e63eb0624e5246c8e8b", expected: :killed, note: "div -> rem"},
    %{stable_id: "883292c5cea6155e159fafa5623972a6", expected: :killed, note: "rem -> div"},
    %{stable_id: "732984a4c8db998c31901d5dbf99321c", expected: :killed, note: "attrs + -> -"},
    %{
      stable_id: "b15e819710f4a60e2c5dc31377cc3c27",
      expected: :killed,
      note: "strict? and -> or"
    },
    %{
      stable_id: "303188d6acf275464e9aba440bfc9ae7",
      expected: :survived,
      note: "loose? remove unary !"
    }
  ]

  @impl Mix.Task
  def run(_argv) do
    Mix.Task.run("app.start")
    started = System.monotonic_time(:millisecond)

    {:ok, oracle} = Mut.OracleBuild.run(@fixture_root, run_id: "m8-oracle", force: true)
    plan = Mut.Orchestrator.plan(@fixture_root, oracle)

    {:ok, schema_result} =
      Mut.SchemaBuild.build(plan,
        user_project_root: @fixture_root,
        run_id: "m8-schema",
        force: true,
        keep: true
      )

    {:ok, pool} =
      Mut.Sandbox.create_pool(schema_result, @concurrency, run_id: "m8-worker", force: true)

    final_pool =
      try do
        selection = Mut.TestSelection.for_plan(schema_result.plan, @fixture_test_paths)
        all_test_files = Mut.TestSelection.discover_test_files(@fixture_test_paths)
        {results, pool} = run_expectations(pool, schema_result.plan, selection, all_test_files)
        summarize!(results, all_test_files, elapsed(started), schema_result.plan)
        pool
      after
        File.rm_rf!(schema_result.work_copy_root)
      end

    Mut.Sandbox.destroy_pool(final_pool)
  end

  defp run_expectations(pool, plan, selection, all_test_files) do
    Enum.reduce(@expectations, {[], pool}, fn expectation, {results, pool} ->
      {result, pool} = run_expected(expectation, pool, plan, selection, all_test_files)
      {[result | results], pool}
    end)
    |> then(fn {results, pool} -> {Enum.reverse(results), pool} end)
  end

  defp run_expected(expectation, pool, plan, selection, all_test_files) do
    mutant = Mut.Plan.find_by_stable_id(plan, expectation.stable_id)

    if is_nil(mutant) do
      raise "expected stable_id not found: #{expectation.stable_id}"
    end

    {:ok, sandbox, checked_out} = Mut.Sandbox.checkout(pool)
    selected = Map.fetch!(selection, mutant.stable_id)
    selected_for_worker = worker_test_files(selected, all_test_files, @fixture_root)

    IO.puts(
      "mutant #{mutant.id} #{String.slice(mutant.stable_id, 0, 8)} #{inspect(mutant.module)} → #{length(selected)} test files"
    )

    result =
      Mut.Worker.run_schema(sandbox, mutant.id, selected_for_worker,
        timeout_ms: @timeout_ms,
        retry_on_error: true
      )

    checked_in = Mut.Sandbox.checkin(sandbox, checked_out)

    {%{
       stable_id: expectation.stable_id,
       mutant_id: mutant.id,
       note: expectation.note,
       expected: expectation.expected,
       actual: result.status,
       killing_test: result.killing_test,
       duration_ms: result.duration_ms,
       module: mutant.module,
       selected_tests: selected,
       selected_count: length(selected),
       raw_output: result.raw_output
     }, checked_in}
  end

  defp summarize!(results, all_test_files, wall_ms, plan) do
    mismatches = Enum.reject(results, &(&1.expected == &1.actual))
    counts = Enum.frequencies_by(results, & &1.actual)
    total_test_files = length(all_test_files)
    selection_size_per_mutant = Enum.map(results, & &1.selected_count)
    reduced_ms = wall_ms
    reduction_pct = Float.round((@m8_baseline_ms - reduced_ms) * 100 / @m8_baseline_ms, 1)

    expected_counts = %{killed: 9, survived: 1}

    IO.puts(
      "mut.test_schema results=#{inspect(counts)} wall_ms=#{wall_ms} baseline_wall_ms=#{@m8_baseline_ms} reduction_pct=#{reduction_pct}"
    )

    IO.puts(
      "mut.test_schema selection_size_per_mutant=#{inspect(selection_size_per_mutant)} total_test_files=#{total_test_files}"
    )

    IO.puts("mut.test_schema selection_summary=#{inspect(selection_summary(results))}")
    validate_stryker_json!(results, plan)

    if mismatches != [] do
      raise "schema integration mismatches: #{inspect(mismatches, pretty: true)}"
    end

    if counts != expected_counts do
      raise "schema integration count mismatch: expected #{inspect(expected_counts)}, got #{inspect(counts)}"
    end

    if not Enum.all?(selection_size_per_mutant, &(&1 < total_test_files)) do
      raise "schema integration selection did not narrow every curated mutant"
    end
  end

  defp validate_stryker_json!(results, plan) do
    {:ok, metrics} = Mut.Metrics.start_link([])

    Enum.each(results, fn result ->
      mutant =
        plan
        |> Mut.Plan.find_by_stable_id(result.stable_id)
        |> Map.put(:covering_tests, result.selected_tests)

      worker_result = %Result{
        status: result.actual,
        duration_ms: result.duration_ms,
        killing_test: result.killing_test,
        raw_output: result.raw_output
      }

      Mut.Metrics.record_mutant(metrics, mutant, worker_result)
    end)

    rendered = StrykerJson.render(Mut.Metrics.snapshot(metrics), plan, &source/1, [])
    :ok = StrykerJson.validate(rendered)
    IO.puts("mut.test_schema stryker_json=:ok")
  end

  defp source(file), do: File.read!(Path.join(@fixture_root, file))

  defp worker_test_files(selected, all_test_files, fixture_root) do
    if selected == [] or length(selected) == length(all_test_files) do
      []
    else
      Enum.map(selected, &Path.relative_to(&1, fixture_root))
    end
  end

  defp selection_summary(results) do
    Enum.map(results, fn result ->
      {String.slice(result.stable_id, 0, 8), result.module, result.selected_count}
    end)
  end

  defp elapsed(started), do: System.monotonic_time(:millisecond) - started
end
