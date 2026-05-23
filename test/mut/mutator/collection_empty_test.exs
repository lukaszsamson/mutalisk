defmodule Mut.Mutator.CollectionEmptyTest do
  use ExUnit.Case, async: true

  alias Mut.Context
  alias Mut.EnvWalker
  alias Mut.Mutator.CollectionEmpty

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
      assert CollectionEmpty.name() == "CollectionEmpty"
      assert CollectionEmpty.targets() == [:env_walker]
    end
  end

  describe "applicable?/2" do
    test "true for non-empty list and any 2-tuple in fallback/body context" do
      assert CollectionEmpty.applicable?({:__block__, [], [[1, 2]]}, ctx([]))
      assert CollectionEmpty.applicable?({:__block__, [], [{:ok, 1}]}, ctx([]))
    end

    test "false for empty list, scalars, wrong context/engine" do
      refute CollectionEmpty.applicable?({:__block__, [], [[]]}, ctx([]))
      refute CollectionEmpty.applicable?({:__block__, [], [42]}, ctx([]))
      refute CollectionEmpty.applicable?({:__block__, [], [[1, 2]]}, ctx(engine: :schema))
      refute CollectionEmpty.applicable?({:__block__, [], [[1, 2]]}, ctx(env_context: :match))
    end
  end

  describe "mutate/2" do
    test "list empties to []" do
      assert [m] = CollectionEmpty.mutate({:__block__, [], [[1, 2]]}, ctx([]))
      assert m.metadata == %{collection: :list}
      assert m.mutation_kind == :collection_empty
      assert match?({:__block__, _, [[]]}, m.mutated_ast)
    end

    test "2-tuple empties to {}" do
      assert [m] = CollectionEmpty.mutate({:__block__, [], [{:ok, 1}]}, ctx([]))
      assert m.metadata == %{collection: :tuple}
      assert match?({:__block__, _, [{}]}, m.mutated_ast)
    end
  end

  describe "end-to-end via env walker" do
    test "collects list and 2-tuple literals; ignores keyword-list args and do-blocks" do
      src = ~S'''
      defmodule Foo do
        def x, do: [1, 2, 3]
        def y, do: {:ok, 7}
        def z, do: String.split("a b", " ", parts: 2)
      end
      '''

      {:ok, ast} = EnvWalker.parse_string(src, "lib/foo.ex")
      pairs = EnvWalker.collect_literal_candidates(ast, file: "lib/foo.ex", source: src)
      names = pairs |> Enum.map(fn {c, _} -> c.syntactic_name end) |> Enum.sort()
      # The `parts: 2` keyword-list arg is structural (unwrapped) and is
      # NOT a collection candidate; only the list and the tuple are.
      assert :__list_literal__ in names
      assert :__tuple_literal__ in names
      colls = Enum.filter(names, &(&1 in [:__list_literal__, :__tuple_literal__]))
      assert length(colls) == 2
    end

    test "does not collect collections in match position" do
      src = ~S'''
      defmodule Foo do
        def x([a, b]), do: a + b
      end
      '''

      {:ok, ast} = EnvWalker.parse_string(src, "lib/foo.ex")
      pairs = EnvWalker.collect_literal_candidates(ast, file: "lib/foo.ex", source: src)

      colls =
        Enum.filter(pairs, fn {c, _} ->
          c.syntactic_name in [:__list_literal__, :__tuple_literal__]
        end)

      assert colls == []
    end
  end
end
