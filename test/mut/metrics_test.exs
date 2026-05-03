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

    snapshot = Metrics.snapshot(metrics)

    assert snapshot.total == 3
    assert snapshot.score == 50.0
    assert snapshot.by_status == %{killed: 1, survived: 1, error: 1}

    assert snapshot.by_engine_status == %{
             {:schema, :killed} => 1,
             {:fallback, :survived} => 1,
             {:fallback, :error} => 1
           }

    assert snapshot.wall_clock_ms == %{schema: 10, fallback: 35, total: 45}
    assert snapshot.rollback_per_file == %{"lib/a.ex" => 2}
    assert snapshot.test_selection_fanout == %{"a" => 2, "b" => 2, "c" => 2}
    assert Enum.map(snapshot.ledger, & &1.stable_id) == ["a", "b", "c"]
  end

  test "invalid and skipped are excluded from score denominator" do
    {:ok, metrics} = Metrics.start_link([])

    Metrics.record_invalid(metrics, mutant(:schema, "invalid", 1))
    Metrics.record_skipped(metrics, %{file: "lib/a.ex", line: 1, reason: :unsupported_dispatch})

    snapshot = Metrics.snapshot(metrics)

    assert snapshot.total == 2
    assert snapshot.score == 100.0
    assert snapshot.by_status == %{invalid: 1, skipped: 1}
    assert snapshot.invalid_by_mutator == %{Mut.MetricsTest => 1}
    assert snapshot.skipped_by_reason == %{unsupported_dispatch: 1}
  end

  test "snapshot is referentially transparent" do
    {:ok, metrics} = Metrics.start_link([])

    Metrics.record_mutant(metrics, mutant(:schema, "a", 1), result(:killed, 10))

    first = Metrics.snapshot(metrics)
    second = Metrics.snapshot(metrics)

    assert first == second
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
