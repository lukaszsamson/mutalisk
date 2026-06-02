defmodule Mut.MetricsTest do
  use ExUnit.Case, async: true

  @moduledoc false

  alias Mut.Metrics
  alias Mut.Mutant
  alias Mut.Worker.Result

  test "record_mutant increments counters and computes score" do
    {:ok, metrics} = Metrics.start_link([])

    Metrics.record_mutant(metrics, mutant(:schema, "a", 1), result(:killed, 10))
    Metrics.record_mutant(metrics, mutant(:fallback, "b", 2), result(:survived, 30))
    Metrics.record_mutant(metrics, mutant(:fallback, "c", 3), result(:error, 5))
    Metrics.record_compile_rollback(metrics, "lib/a.ex", 2)
    Metrics.set_planned_total(metrics, 10)

    snapshot = Metrics.snapshot(metrics)

    assert snapshot.total == 3
    assert snapshot.planned_total == 10
    assert snapshot.score == 50.0
    assert snapshot.by_status == %{killed: 1, survived: 1, error: 1}

    assert snapshot.by_engine_status == %{
             {:schema, :killed} => 1,
             {:fallback, :survived} => 1,
             {:fallback, :error} => 1
           }

    assert snapshot.wall_clock_ms == %{schema: 10, fallback: 35, total: 45}
    assert snapshot.phase_timings.coverage_collection_ms == 0
    assert is_integer(snapshot.phase_timings.total_ms)
    assert_in_delta snapshot.fallback_count_pct, 66.666, 0.001
    assert snapshot.rollback_per_file == %{"lib/a.ex" => 2}
    assert snapshot.test_selection_fanout == %{"a" => 2, "b" => 2, "c" => 2}
    assert snapshot.selection.mode == :static
    assert snapshot.selection.coverage_collection_wall_ms == 0
    assert Enum.map(snapshot.ledger, & &1.stable_id) == ["a", "b", "c"]
  end

  test "records selection metrics" do
    {:ok, metrics} = Metrics.start_link([])

    Metrics.set_selection_mode(metrics, :coverage_with_static_fallback)
    Metrics.set_coverage_collection_wall_ms(metrics, 123)
    Metrics.record_selection(metrics, mutant(:schema, "a", 1), :exact_line, nil, 1)

    Metrics.record_selection(
      metrics,
      mutant(:schema, "b", 2),
      :static_fallback,
      :no_line_coverage,
      5
    )

    Metrics.record_selection(
      metrics,
      mutant(:schema, "c", 3),
      :all_tests,
      :no_function_coverage,
      9
    )

    snapshot = Metrics.snapshot(metrics)

    assert snapshot.selection == %{
             mode: :coverage_with_static_fallback,
             coverage_match_distribution: %{
               exact_line: 1,
               enclosing_function: 0,
               static_fallback: 1,
               all_tests: 1
             },
             fallback_reason_distribution: %{no_line_coverage: 1, no_function_coverage: 1},
             selected_tests_avg: 5.0,
             selected_tests_median: 5,
             coverage_collection_wall_ms: 123
           }
  end

  test "invalid and skipped are excluded from score denominator" do
    {:ok, metrics} = Metrics.start_link([])

    Metrics.record_invalid(metrics, mutant(:schema, "invalid", 1))
    Metrics.record_skipped(metrics, %{file: "lib/a.ex", line: 1, reason: :unsupported_dispatch})

    snapshot = Metrics.snapshot(metrics)

    assert snapshot.total == 0
    assert snapshot.score == 100.0
    assert snapshot.by_status == %{invalid: 1, skipped: 1}
    assert snapshot.invalid_by_mutator == %{Mut.MetricsTest => 1}
    assert snapshot.skipped_by_reason == %{unsupported_dispatch: 1}
  end

  test "timeout counts as a detection in the mutation score (numerator + denominator)" do
    {:ok, metrics} = Metrics.start_link([])

    # 1 killed, 2 timeout, 1 survived. Per the SPEC / Stryker HTML viewer,
    # timeout is a detection: score = (1 + 2) / (1 + 2 + 1) = 75.0.
    Metrics.record_mutant(metrics, mutant(:schema, "k", 1), result(:killed, 10))
    Metrics.record_mutant(metrics, mutant(:schema, "t1", 2), result(:timeout, 11_000))
    Metrics.record_mutant(metrics, mutant(:fallback, "t2", 3), result(:timeout, 11_000))
    Metrics.record_mutant(metrics, mutant(:fallback, "s", 4), result(:survived, 30))

    snapshot = Metrics.snapshot(metrics)

    assert snapshot.score == 75.0
    assert snapshot.by_status == %{killed: 1, timeout: 2, survived: 1}
  end

  test "snapshot is referentially transparent" do
    {:ok, metrics} = Metrics.start_link([])

    Metrics.record_mutant(metrics, mutant(:schema, "a", 1), result(:killed, 10))

    first = Metrics.snapshot(metrics)
    second = Metrics.snapshot(metrics)

    assert %{first | phase_timings: %{first.phase_timings | total_ms: 0}} ==
             %{second | phase_timings: %{second.phase_timings | total_ms: 0}}
  end

  test "with_phase records elapsed milliseconds" do
    {:ok, metrics} = Metrics.start_link([])

    Metrics.with_phase(metrics, :oracle_build, fn -> Process.sleep(50) end)

    snapshot = Metrics.snapshot(metrics)
    assert snapshot.phase_timings.oracle_build_ms in 40..90
  end

  test "ending a phase without a start records zero" do
    {:ok, metrics} = Metrics.start_link([])

    assert :ok = Metrics.end_phase(metrics, :schema_build)

    assert Metrics.snapshot(metrics).phase_timings.schema_build_ms == 0
  end

  defp result(status, duration_ms) do
    %Result{status: status, duration_ms: duration_ms, killing_test: "DemoTest test"}
  end

  defp mutant(engine, stable_id, id) do
    %Mutant{
      id: id,
      stable_id: stable_id,
      engine: engine,
      mutator: __MODULE__,
      mutator_name: "TestMutator",
      mutation_kind: :test_kind,
      original_dispatch: "+/2",
      file: "lib/a.ex",
      line: id,
      column: 1,
      span: {id, 1, id, 5},
      original_ast: quote(do: a + b),
      mutated_ast: quote(do: a - b),
      description: "replace + with -",
      covering_tests: ["test/a_test.exs", "test/b_test.exs"]
    }
  end
end
