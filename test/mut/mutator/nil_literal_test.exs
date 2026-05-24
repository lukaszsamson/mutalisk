defmodule Mut.Mutator.NilLiteralTest do
  use ExUnit.Case, async: true

  alias Mut.Context
  alias Mut.EnvWalker
  alias Mut.Mutator.NilLiteral

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
      assert NilLiteral.name() == "NilLiteral"
      assert NilLiteral.targets() == [:env_walker]
    end
  end

  describe "applicable?/2" do
    test "true for a nil body literal in fallback/body context" do
      assert NilLiteral.applicable?({:__block__, [], [nil]}, ctx([]))
    end

    test "false for non-nil atoms and match/guard; true under schema engine (M52)" do
      refute NilLiteral.applicable?({:__block__, [], [:ok]}, ctx([]))
      refute NilLiteral.applicable?({:__block__, [], [true]}, ctx([]))
      assert NilLiteral.applicable?({:__block__, [], [nil]}, ctx(engine: :schema))
      refute NilLiteral.applicable?({:__block__, [], [nil]}, ctx(env_context: :match))
      refute NilLiteral.applicable?({:__block__, [], [nil]}, ctx(env_context: :guard))
    end
  end

  describe "mutate/2" do
    test "nil maps to the :__mut_nil__ sentinel" do
      [m] = NilLiteral.mutate({:__block__, [], [nil]}, ctx([]))
      assert m.metadata == %{from: nil, to: :__mut_nil__}
      assert m.mutation_kind == :nil_literal
      assert match?({:__block__, _, [:__mut_nil__]}, m.mutated_ast)
    end

    test "no mutations for ineligible nodes" do
      assert NilLiteral.mutate({:__block__, [], [:ok]}, ctx([])) == []
    end
  end

  describe "end-to-end via env walker" do
    test "collects a nil-literal candidate from a function body" do
      src = ~S'''
      defmodule Foo do
        def x do
          nil
        end
      end
      '''

      {:ok, ast} = EnvWalker.parse_string(src, "lib/foo.ex")
      pairs = EnvWalker.collect_literal_candidates(ast, file: "lib/foo.ex", source: src)
      nils = Enum.filter(pairs, fn {c, _} -> c.syntactic_name == :__nil_literal__ end)
      assert [{candidate, snap}] = nils
      assert {:__block__, _, [nil]} = candidate.node
      assert snap.scope == :function_body
    end
  end
end
