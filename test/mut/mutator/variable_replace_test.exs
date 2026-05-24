defmodule Mut.Mutator.VariableReplaceTest do
  use ExUnit.Case, async: true

  alias Mut.Context
  alias Mut.Mutator.VariableReplace

  defp ctx(overrides) do
    base = %Context{
      engine: :fallback,
      env_context: nil,
      file: "lib/foo.ex",
      ast_path: [],
      ast_path_hash: <<0>>,
      bound_vars: [:b, :c]
    }

    struct(base, overrides)
  end

  describe "metadata" do
    test "name and targets" do
      assert VariableReplace.name() == "VariableReplace"
      assert VariableReplace.targets() == [:variable]
    end
  end

  describe "applicable?/2" do
    test "true for a variable read with at least one alternative" do
      assert VariableReplace.applicable?({:a, [], nil}, ctx([]))
    end

    test "false with no alternatives" do
      refute VariableReplace.applicable?({:a, [], nil}, ctx(bound_vars: []))
      refute VariableReplace.applicable?({:a, [], nil}, ctx(bound_vars: nil))
    end

    test "false in match/guard context and under the schema engine" do
      refute VariableReplace.applicable?({:a, [], nil}, ctx(env_context: :match))
      refute VariableReplace.applicable?({:a, [], nil}, ctx(env_context: :guard))
      refute VariableReplace.applicable?({:a, [], nil}, ctx(engine: :schema))
    end

    test "false for non-variable nodes (calls, literals)" do
      refute VariableReplace.applicable?({:foo, [], []}, ctx([]))
      refute VariableReplace.applicable?({:__block__, [], [1]}, ctx([]))
    end
  end

  describe "mutate/2" do
    test "produces one mutation per alternative, excluding self" do
      mutations = VariableReplace.mutate({:a, [line: 1], nil}, ctx(bound_vars: [:a, :b, :c]))
      assert Enum.map(mutations, & &1.metadata.to) == [:b, :c]
      assert Enum.all?(mutations, &(&1.mutation_kind == :variable_replace))
      assert {:b, [line: 1], nil} in Enum.map(mutations, & &1.mutated_ast)
    end

    test "caps the number of alternatives" do
      mutations = VariableReplace.mutate({:a, [], nil}, ctx(bound_vars: [:b, :c, :d, :e, :f]))
      assert length(mutations) == 3
    end

    test "no mutations when inapplicable" do
      assert VariableReplace.mutate({:a, [], nil}, ctx(bound_vars: [])) == []
    end
  end
end
