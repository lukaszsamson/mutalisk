defmodule Mut.Reporter.StrykerJsonGoldenTest do
  use ExUnit.Case, async: false

  @moduledoc false
  @moduletag :golden_oracle

  alias Mut.Metrics.Snapshot
  alias Mut.Mutant
  alias Mut.Plan
  alias Mut.Reporter.StrykerJson

  @golden Path.expand("test/golden/stryker/synthetic_plan.json")

  test "synthetic plan matches Stryker JSON golden" do
    {snapshot, plan} = synthetic_snapshot_and_plan()
    rendered = StrykerJson.render(snapshot, plan, source_loader(), [])

    assert :ok = StrykerJson.validate(rendered)

    actual = Jason.encode!(rendered, pretty: true) <> "\n"

    if System.get_env("MUT_REGOLD") == "1" do
      File.mkdir_p!(Path.dirname(@golden))
      File.write!(@golden, actual)
    end

    assert actual == File.read!(@golden)
  end

  defp synthetic_snapshot_and_plan do
    schema = [
      mutant(1, "stable-killed", :schema, :killed),
      mutant(2, "stable-survived", :schema, :survived),
      mutant(3, "stable-timeout", :schema, :timeout)
    ]

    fallback = [
      mutant(4, "stable-error", :fallback, :error),
      mutant(5, "stable-skipped", :fallback, :skipped)
    ]

    invalid = [mutant(6, "stable-invalid", :schema, :invalid)]
    mutants = schema ++ fallback ++ invalid

    snapshot = %Snapshot{
      total: length(mutants),
      score: 50.0,
      by_status: Enum.frequencies(Enum.map(mutants, & &1.status)),
      by_engine_status: Enum.frequencies(Enum.map(mutants, &{&1.engine, &1.status})),
      fallback_count_pct: 100.0 / 3.0,
      wall_clock_ms: %{schema: 60, fallback: 90, total: 150},
      rollback_per_file: %{"lib/synthetic.ex" => 1},
      invalid_by_mutator: %{__MODULE__ => 1},
      skipped_by_reason: %{unsupported_dispatch: 1},
      test_selection_fanout: Map.new(mutants, &{&1.stable_id, length(&1.covering_tests || [])}),
      ledger: Enum.map(mutants, &entry/1)
    }

    {snapshot, %Plan{schema: schema, fallback: fallback, invalid: invalid, skipped: []}}
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

  defp mutant(id, stable_id, engine, status) do
    %Mutant{
      id: id,
      stable_id: stable_id,
      engine: engine,
      mutator: __MODULE__,
      mutator_name: mutator_name(engine),
      mutation_kind: mutation_kind(engine),
      original_dispatch: original_dispatch(engine),
      file: "lib/synthetic.ex",
      line: id + 1,
      column: 7,
      span: {id + 1, 7, id + 1, 12},
      original_ast: quote(do: value + 1),
      mutated_ast: mutated_ast(engine),
      description: description(engine),
      status: status,
      skip_reason: skip_reason(status),
      compile_error: compile_error(status),
      covering_tests: ["SyntheticTest:case_#{id}"],
      killing_test: killing_test(status, id),
      duration_ms: id * 10
    }
  end

  defp mutator_name(:schema), do: "Arithmetic"
  defp mutator_name(:fallback), do: "GuardComparisonBoundary"

  defp mutation_kind(:schema), do: :arithmetic_op
  defp mutation_kind(:fallback), do: :guard_comparison_boundary

  defp original_dispatch(:schema), do: "+/2"
  defp original_dispatch(:fallback), do: "guard:>/2"

  defp mutated_ast(:schema), do: quote(do: value - 1)
  defp mutated_ast(:fallback), do: quote(do: value >= 1)

  defp description(:schema), do: "replace + with -"
  defp description(:fallback), do: "replace guard > with >="

  defp skip_reason(:skipped), do: :unsupported_dispatch
  defp skip_reason(_status), do: nil

  defp compile_error(:invalid), do: "synthetic compile error"
  defp compile_error(_status), do: nil

  defp killing_test(:killed, id), do: "SyntheticTest case_#{id}"
  defp killing_test(_status, _id), do: nil

  defp source_loader do
    fn "lib/synthetic.ex" ->
      "defmodule Synthetic do\n  def value(value), do: value + 1\n  def positive?(value) when value > 1, do: true\nend\n"
    end
  end
end
