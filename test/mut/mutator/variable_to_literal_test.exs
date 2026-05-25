defmodule Mut.Mutator.VariableToLiteralTest do
  use ExUnit.Case, async: true

  alias Mut.Context
  alias Mut.Mutator.VariableToLiteral

  defp ctx(overrides) do
    base = %Context{
      engine: :fallback,
      env_context: nil,
      file: "lib/foo.ex",
      ast_path: [],
      ast_path_hash: <<0>>,
      type_hint: :number
    }

    struct(base, overrides)
  end

  describe "metadata" do
    test "name and targets" do
      assert VariableToLiteral.name() == "VariableToLiteral"
      assert VariableToLiteral.targets() == [:variable]
    end
  end

  describe "applicable?/2" do
    test "true for a variable read with a supported type hint" do
      for hint <- [:number, :binary, :list, :boolean] do
        assert VariableToLiteral.applicable?({:a, [], nil}, ctx(type_hint: hint))
      end
    end

    test "false without a hint, with an unsupported hint, or in match/guard/schema" do
      refute VariableToLiteral.applicable?({:a, [], nil}, ctx(type_hint: nil))
      refute VariableToLiteral.applicable?({:a, [], nil}, ctx(type_hint: :map))
      refute VariableToLiteral.applicable?({:a, [], nil}, ctx(env_context: :match))
      refute VariableToLiteral.applicable?({:a, [], nil}, ctx(env_context: :guard))
      refute VariableToLiteral.applicable?({:a, [], nil}, ctx(engine: :schema))
    end

    test "false for non-variable nodes" do
      refute VariableToLiteral.applicable?({:foo, [], []}, ctx([]))
      refute VariableToLiteral.applicable?({:__block__, [], [1]}, ctx([]))
    end
  end

  describe "mutate/2" do
    test "maps each hint to its boundary literal" do
      assert [%{mutated_ast: 0, metadata: %{to: 0}}] =
               VariableToLiteral.mutate({:a, [], nil}, ctx(type_hint: :number))

      assert [%{mutated_ast: ""}] =
               VariableToLiteral.mutate({:a, [], nil}, ctx(type_hint: :binary))

      assert [%{mutated_ast: []}] =
               VariableToLiteral.mutate({:a, [], nil}, ctx(type_hint: :list))

      assert [%{mutated_ast: false}] =
               VariableToLiteral.mutate({:a, [], nil}, ctx(type_hint: :boolean))
    end

    test "mutation_kind and no mutations when inapplicable" do
      [m] = VariableToLiteral.mutate({:a, [], nil}, ctx(type_hint: :number))
      assert m.mutation_kind == :variable_to_literal
      assert VariableToLiteral.mutate({:a, [], nil}, ctx(type_hint: nil)) == []
    end
  end
end
