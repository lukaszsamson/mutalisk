defmodule Mut.PlanTest do
  use ExUnit.Case, async: true

  @moduledoc false

  alias Mut.Mutant
  alias Mut.Plan

  test "dump_json produces deterministic sorted output" do
    plan = %Plan{
      schema: [mutant("b", 2), mutant("a", 1)],
      fallback: [],
      invalid: [],
      skipped: [skip("b.ex", 2, :z), skip("a.ex", 1, :a)]
    }

    assert Plan.dump_json(plan) == Plan.dump_json(plan)
    assert String.contains?(Plan.dump_json(plan), "\n  \"schema\": [")
  end

  test "round-trip decoded values are stable" do
    json = Plan.dump_json(%Plan{schema: [mutant("a", 1)], fallback: [], invalid: [], skipped: []})
    decoded = Jason.decode!(json)

    second =
      Jason.decode!(
        Plan.dump_json(%Plan{schema: [mutant("a", 1)], fallback: [], invalid: [], skipped: []})
      )

    assert decoded == second
  end

  test "mutant AST fields are excluded from JSON output" do
    json = Plan.dump_json(%Plan{schema: [mutant("a", 1)], fallback: [], invalid: [], skipped: []})

    refute String.contains?(json, "original_ast")
    refute String.contains?(json, "mutated_ast")
  end

  defp mutant(stable_id, id) do
    %Mutant{
      id: id,
      stable_id: stable_id,
      engine: :schema,
      mutator: Mut.Mutator.Arithmetic,
      mutator_name: "Arithmetic",
      mutation_kind: :arithmetic_op,
      stable_id_kind: "arithmetic_op:operator=:+,replacement=:-",
      original_dispatch: "Kernel.+/2",
      ast_path_hash: "hash",
      file: "lib/a.ex",
      line: 1,
      original_ast: {:+, [], [1, 2]},
      mutated_ast: {:-, [], [1, 2]},
      description: "replace + with -"
    }
  end

  defp skip(file, line, name) do
    %{
      file: file,
      line: line,
      column: nil,
      syntactic_name: name,
      reason: :missing_oracle_site,
      detail: nil
    }
  end
end
