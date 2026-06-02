defmodule Mut.Reporter.StrykerJsonTest do
  use ExUnit.Case, async: true

  @moduledoc false

  alias Mut.Metrics.Snapshot
  alias Mut.Mutant
  alias Mut.Plan
  alias Mut.Reporter.StrykerJson

  test "render produces schema v2 shape and round-trips through JSON" do
    {snapshot, plan} = fixture_snapshot_and_plan([:killed])

    rendered = StrykerJson.render(snapshot, plan, source_loader(), [])
    decoded = rendered |> Mut.JSON.encode!() |> Mut.JSON.decode!()

    assert Map.keys(decoded) |> Enum.sort() == [
             "files",
             "mutalisk",
             "schemaVersion",
             "thresholds"
           ]

    assert rendered["schemaVersion"] == "2"
    assert rendered["files"]["lib/a.ex"]["language"] == "elixir"
    assert [mutant] = rendered["files"]["lib/a.ex"]["mutants"]
    assert mutant["id"] == "stable-killed"
    assert mutant["replacement"] == "a - b"
    assert mutant["status"] == "Killed"
    assert rendered["mutalisk"]["engine"] == %{"stable-killed" => "schema"}
    assert rendered["mutalisk"]["phase_timings"]["oracle_build_ms"] == 1000
    assert rendered["mutalisk"]["selection"]["mode"] == "coverage_with_static_fallback"
  end

  test "M99: terminal score (snapshot.score) and Stryker-viewer-derived score agree" do
    # killed=1, timeout=1 (both detected), survived=1; error excluded.
    {snapshot, plan} = fixture_snapshot_and_plan([:killed, :timeout, :survived, :error])

    rendered = StrykerJson.render(snapshot, plan, source_loader(), [])
    decoded = rendered |> Mut.JSON.encode!() |> Mut.JSON.decode!()

    status_counts =
      decoded["files"]
      |> Map.values()
      |> Enum.flat_map(& &1["mutants"])
      |> Enum.frequencies_by(& &1["status"])

    # Stryker HTML viewer: detected = Killed + Timeout; undetected = Survived +
    # NoCoverage; score = detected / (detected + undetected). CompileError /
    # RuntimeError / Ignored are excluded from both.
    detected = Map.get(status_counts, "Killed", 0) + Map.get(status_counts, "Timeout", 0)
    undetected = Map.get(status_counts, "Survived", 0) + Map.get(status_counts, "NoCoverage", 0)
    stryker_score = detected / (detected + undetected) * 100.0

    # The terminal reporter prints snapshot.score. Both must agree, and both
    # must count the timeout as a detection: (1 killed + 1 timeout) / (2 + 1
    # survived) = 66.7%. The pre-fix bug excluded timeout → terminal 50%.
    assert_in_delta snapshot.score, stryker_score, 0.001
    assert_in_delta snapshot.score, 66.7, 0.05
  end

  test "M47: a heredoc-delimited mutant diff degrades instead of aborting the report" do
    # `Macro.to_string/1` renders this as a heredoc fragment that
    # `Code.format_string!/1` cannot re-parse (TokenMissingError) — the
    # M46 plug-run crash. The report must still render.
    trap_ast = {:__block__, [delimiter: ~s["""], line: 1, column: 1], ["some text\n"]}

    {snapshot, plan} = fixture_snapshot_and_plan([:survived])
    [mutant] = plan.schema
    mutant = %{mutant | mutated_ast: trap_ast}
    plan = %{plan | schema: [mutant]}
    snapshot = %{snapshot | ledger: [%{entry(mutant) | mutant: mutant}]}

    rendered = StrykerJson.render(snapshot, plan, source_loader(), [])
    decoded = rendered |> Mut.JSON.encode!() |> Mut.JSON.decode!()

    [result] = decoded["files"]["lib/a.ex"]["mutants"]
    assert is_binary(result["replacement"])
    # Degraded to the unformatted render (still informative), not crashed.
    assert result["replacement"] =~ "some text"
    assert :ok = StrykerJson.validate(rendered)
  end

  test "validate accepts known good shape and rejects missing fields" do
    {snapshot, plan} = fixture_snapshot_and_plan([:killed])
    rendered = StrykerJson.render(snapshot, plan, source_loader(), [])

    assert :ok = StrykerJson.validate(rendered)

    invalid = put_in(rendered, ["files", "lib/a.ex", "mutants"], [%{"id" => "missing"}])

    assert {:error, violations} = StrykerJson.validate(invalid)
    assert Enum.any?(violations, &String.contains?(&1, "mutatorName"))
    assert Enum.any?(violations, &String.contains?(&1, "location"))
  end

  test "status mapping is closed and matches Stryker strings" do
    assert StrykerJson.status(:pending) == nil

    Enum.each(
      [
        killed: "Killed",
        survived: "Survived",
        timeout: "Timeout",
        invalid: "CompileError",
        error: "RuntimeError",
        skipped: "Ignored"
      ],
      fn {status, expected} -> assert StrykerJson.status(status) == expected end
    )
  end

  defp fixture_snapshot_and_plan(statuses) do
    mutants = Enum.map(statuses, &mutant/1)

    snapshot = %Snapshot{
      total: length(mutants),
      score: 100.0,
      by_status: Enum.frequencies(Enum.map(mutants, & &1.status)),
      by_engine_status: Enum.frequencies(Enum.map(mutants, &{&1.engine, &1.status})),
      fallback_count_pct: 0.0,
      wall_clock_ms: %{schema: 7, fallback: 0, total: 7},
      rollback_per_file: %{},
      invalid_by_mutator: %{},
      skipped_by_reason: %{},
      test_selection_fanout: Map.new(mutants, &{&1.stable_id, length(&1.covering_tests || [])}),
      phase_timings: %{
        oracle_build_ms: 1000,
        baseline_tests_ms: 2000,
        plan_generation_ms: 300,
        coverage_collection_ms: 0,
        schema_build_ms: 4000,
        schema_workers_ms: 5000,
        fallback_workers_ms: 6000,
        report_writing_ms: 70,
        total_ms: 18_370
      },
      selection: %{
        mode: :coverage_with_static_fallback,
        coverage_match_distribution: %{
          exact_line: length(mutants),
          enclosing_function: 0,
          static_fallback: 0,
          all_tests: 0
        },
        fallback_reason_distribution: %{},
        selected_tests_avg: 1.0,
        selected_tests_median: 1,
        coverage_collection_wall_ms: 123
      },
      concurrency: %{configured: 4, effective: 4, schedulers_online: 8},
      recompile_categories: %{compile_error: 0, dep_path_error: 0, unknown: 0},
      ledger: Enum.map(mutants, &entry/1)
    }

    {%{snapshot | score: score(snapshot.by_status)},
     %Plan{schema: mutants, fallback: [], skipped: []}}
  end

  # Mirror Mut.Metrics.score/3: timeout is a detection, counted with killed in
  # both numerator and denominator; error/invalid/skipped excluded.
  defp score(counts) do
    killed = Map.get(counts, :killed, 0)
    timeout = Map.get(counts, :timeout, 0)
    survived = Map.get(counts, :survived, 0)
    detected = killed + timeout
    total = detected + survived
    if total == 0, do: 100.0, else: detected / total * 100.0
  end

  defp entry(mutant) do
    %{
      id: mutant.id,
      stable_id: mutant.stable_id,
      engine: mutant.engine,
      status: mutant.status,
      mutation_kind: mutant.mutation_kind,
      duration_ms: mutant.duration_ms,
      killing_test: mutant.killing_test,
      mutant: mutant,
      result: nil
    }
  end

  defp mutant(status) do
    %Mutant{
      id: 1,
      stable_id: "stable-#{status}",
      engine: :schema,
      mutator: __MODULE__,
      mutator_name: "Arithmetic",
      mutation_kind: :arithmetic_op,
      original_dispatch: "+/2",
      file: "lib/a.ex",
      line: 3,
      column: 5,
      span: {3, 5, 3, 10},
      original_ast: quote(do: a + b),
      mutated_ast: quote(do: a - b),
      description: "replace + with -",
      status: status,
      covering_tests: ["A.Test:passes"],
      killing_test: "A.Test fails",
      duration_ms: 7
    }
  end

  defp source_loader do
    fn
      "lib/a.ex" -> "defmodule A do\n  def add(a, b), do: a + b\nend\n"
    end
  end
end
