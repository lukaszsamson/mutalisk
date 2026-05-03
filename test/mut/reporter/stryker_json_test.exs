defmodule Mut.Reporter.StrykerJsonTest do
  use ExUnit.Case, async: true

  @moduledoc false

  alias Mut.Metrics.Snapshot
  alias Mut.Mutant
  alias Mut.Plan
  alias Mut.Reporter.StrykerJson

  test "render produces schema v2 shape and round-trips through Jason" do
    {snapshot, plan} = fixture_snapshot_and_plan([:killed])

    rendered = StrykerJson.render(snapshot, plan, source_loader(), [])
    decoded = rendered |> Jason.encode!() |> Jason.decode!()

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
      wall_clock_ms: %{schema: 7, fallback: 0, total: 7},
      rollback_per_file: %{},
      invalid_by_mutator: %{},
      skipped_by_reason: %{},
      test_selection_fanout: Map.new(mutants, &{&1.stable_id, length(&1.covering_tests || [])}),
      ledger: Enum.map(mutants, &entry/1)
    }

    {%{snapshot | score: score(snapshot.by_status)},
     %Plan{schema: mutants, fallback: [], skipped: []}}
  end

  defp score(%{killed: killed, survived: survived}), do: killed / (killed + survived) * 100.0
  defp score(%{killed: _killed}), do: 100.0
  defp score(_counts), do: 100.0

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
