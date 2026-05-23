defmodule Mut.Mutator.FloatLiteralTest do
  use ExUnit.Case, async: true

  alias Mut.Context
  alias Mut.EnvWalker
  alias Mut.Mutator.FloatLiteral

  defp ctx(overrides) do
    base = %Context{
      engine: :fallback,
      env_context: nil,
      file: "lib/foo.ex",
      ast_path: [],
      ast_path_hash: <<0>>
    }

    struct(base, overrides)
  end

  describe "metadata" do
    test "name and targets" do
      assert FloatLiteral.name() == "FloatLiteral"
      assert FloatLiteral.targets() == [:env_walker]
    end
  end

  describe "applicable?/2" do
    test "true for a float body literal in fallback/body context" do
      assert FloatLiteral.applicable?({:__block__, [], [1.5]}, ctx([]))
    end

    test "false for non-floats, schema engine, and match/guard context" do
      refute FloatLiteral.applicable?({:__block__, [], [42]}, ctx([]))
      refute FloatLiteral.applicable?({:__block__, [], ["s"]}, ctx([]))
      refute FloatLiteral.applicable?({:__block__, [], [1.5]}, ctx(engine: :schema))
      refute FloatLiteral.applicable?({:__block__, [], [1.5]}, ctx(env_context: :match))
      refute FloatLiteral.applicable?({:__block__, [], [1.5]}, ctx(env_context: :guard))
    end
  end

  describe "mutate/2" do
    test "0.0 maps to 1.0 only" do
      [m] = FloatLiteral.mutate({:__block__, [], [0.0]}, ctx([]))
      assert m.metadata == %{from: 0.0, to: 1.0}
      assert m.mutation_kind == :float_literal
    end

    test "finite non-zero float maps to 0.0 and f + 1.0" do
      mutations = FloatLiteral.mutate({:__block__, [], [2.5]}, ctx([]))
      assert Enum.map(mutations, & &1.metadata.to) == [0.0, 3.5]
      assert Enum.all?(mutations, &match?({:__block__, _, [v]} when is_float(v), &1.mutated_ast))
    end

    test "no mutations for ineligible nodes" do
      assert FloatLiteral.mutate({:__block__, [], [1]}, ctx([])) == []
    end
  end

  describe "end-to-end via env walker" do
    test "collects a float-literal candidate from a function body" do
      src = ~S'''
      defmodule Foo do
        def x do
          3.14
        end
      end
      '''

      {:ok, ast} = EnvWalker.parse_string(src, "lib/foo.ex")
      pairs = EnvWalker.collect_literal_candidates(ast, file: "lib/foo.ex", source: src)
      floats = Enum.filter(pairs, fn {c, _} -> c.syntactic_name == :__float_literal__ end)
      assert [{candidate, snap}] = floats
      assert {:__block__, _, [3.14]} = candidate.node
      assert snap.scope == :function_body
    end
  end
end
