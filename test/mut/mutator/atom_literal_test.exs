defmodule Mut.Mutator.AtomLiteralTest do
  use ExUnit.Case, async: true

  alias Mut.Context
  alias Mut.EnvWalker
  alias Mut.Mutator.AtomLiteral

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
      assert AtomLiteral.name() == "AtomLiteral"
      assert AtomLiteral.targets() == [:env_walker]
    end
  end

  describe "applicable?/2" do
    test "true only for allowlisted atoms in fallback/body context" do
      assert AtomLiteral.applicable?({:__block__, [], [:ok]}, ctx([]))
      assert AtomLiteral.applicable?({:__block__, [], [:lt]}, ctx([]))
    end

    test "false for non-allowlisted atoms, booleans, nil, and wrong context" do
      refute AtomLiteral.applicable?({:__block__, [], [:something_else]}, ctx([]))
      refute AtomLiteral.applicable?({:__block__, [], [true]}, ctx([]))
      refute AtomLiteral.applicable?({:__block__, [], [nil]}, ctx([]))
      refute AtomLiteral.applicable?({:__block__, [], [:ok]}, ctx(engine: :schema))
      refute AtomLiteral.applicable?({:__block__, [], [:ok]}, ctx(env_context: :match))
    end
  end

  describe "mutate/2" do
    test ":ok and :error swap (single replacement each)" do
      assert [m] = AtomLiteral.mutate({:__block__, [], [:ok]}, ctx([]))
      assert m.metadata == %{from: :ok, to: :error}
      assert m.mutation_kind == :atom_literal

      assert [m2] = AtomLiteral.mutate({:__block__, [], [:error]}, ctx([]))
      assert m2.metadata.to == :ok
    end

    test "comparison atoms map to the other two (never synthesize new atoms)" do
      tos = AtomLiteral.mutate({:__block__, [], [:lt]}, ctx([])) |> Enum.map(& &1.metadata.to)
      assert tos == [:gt, :eq]
    end

    test "no mutations for ineligible nodes" do
      assert AtomLiteral.mutate({:__block__, [], [:nope]}, ctx([])) == []
    end
  end

  describe "end-to-end via env walker" do
    test "collects allowlisted and non-allowlisted atoms as candidates (mutator filters)" do
      src = ~S'''
      defmodule Foo do
        def x, do: :ok
        def y, do: :custom
      end
      '''

      {:ok, ast} = EnvWalker.parse_string(src, "lib/foo.ex")
      pairs = EnvWalker.collect_literal_candidates(ast, file: "lib/foo.ex", source: src)
      atoms = Enum.filter(pairs, fn {c, _} -> c.syntactic_name == :__atom_literal__ end)
      assert length(atoms) == 2
    end
  end
end
