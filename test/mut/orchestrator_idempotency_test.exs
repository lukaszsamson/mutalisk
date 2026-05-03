defmodule Mut.OrchestratorIdempotencyTest do
  use ExUnit.Case, async: false

  @moduledoc false

  @fixture_root Path.expand("test/fixtures/demo_app")

  test "planning demo_app is deterministic" do
    oracle = Mut.FixtureOracleHelper.golden_oracle()
    first = Mut.Orchestrator.plan(@fixture_root, oracle)
    second = Mut.Orchestrator.plan(@fixture_root, oracle)

    assert stable_ids(first) == stable_ids(second)
    assert id_assignment(first) == id_assignment(second)
    assert membership(first) == membership(second)
  end

  defp stable_ids(plan), do: plan |> mutants() |> Enum.map(& &1.stable_id) |> Enum.sort()

  defp id_assignment(plan),
    do: plan |> mutants() |> Enum.map(&{&1.stable_id, &1.id}) |> Enum.sort()

  defp mutants(plan), do: plan.schema ++ plan.fallback

  defp membership(plan) do
    %{
      schema: Enum.map(plan.schema, & &1.stable_id) |> Enum.sort(),
      fallback: Enum.map(plan.fallback, & &1.stable_id) |> Enum.sort(),
      skipped:
        Enum.map(plan.skipped, &{&1.file, &1.line, &1.syntactic_name, &1.reason})
        |> Enum.sort()
    }
  end
end
