defmodule Mut.Mutator.StatementDeleteTest do
  use ExUnit.Case, async: true

  @moduledoc "M81 StatementDelete + AstWalk.statement_delete_candidates."

  alias Mut.AstWalk
  alias Mut.Context
  alias Mut.Mutator.StatementDelete

  defp candidates(src) do
    ast = Code.string_to_quoted!(src, columns: true, token_metadata: true)
    AstWalk.statement_delete_candidates(ast, file: "m.ex", source: src)
  end

  defp ctx(ast_path),
    do: %Context{engine: :fallback, file: "m.ex", ast_path: ast_path, ast_path_hash: "h"}

  describe "metadata" do
    test "name/targets" do
      assert StatementDelete.name() == "StatementDelete"
      assert StatementDelete.targets() == [:statement_delete]
    end
  end

  describe "AstWalk.statement_delete_candidates" do
    test "emits one candidate per non-last statement; last excluded" do
      src = """
      defmodule M do
        def f(x) do
          IO.puts("a")
          IO.puts("b")
          x + 1
        end
      end
      """

      cands = candidates(src)
      assert length(cands) == 2
      indexes = Enum.map(cands, fn c -> List.last(c.ast_path) end)
      assert indexes == [0, 1]
      # All candidates share the def's whole-node span.
      assert Enum.all?(cands, fn c -> c.source_span != nil end)
    end

    test "skips functions whose body is a single expression (no __block__)" do
      src = """
      defmodule N do
        def g(a), do: a + 1
      end
      """

      assert candidates(src) == []
    end

    test "M81 orphan-binding hazard: skips deletion of a stmt whose binding is read later" do
      src = """
      defmodule O do
        def h(a) do
          x = a + 1
          y = a + 2
          x + y
        end
      end
      """

      # `x = a + 1` is read on the final line -> deletion would break compile.
      # `y = a + 2` is also read on the final line -> deletion would break.
      # Both non-last stmts are orphan-binding hazards -> no candidates.
      assert candidates(src) == []
    end

    test "emits when a deleted stmt's binding is NOT read later" do
      src = """
      defmodule P do
        def k(a) do
          _unused = side_effect(a)
          a + 1
        end
      end
      """

      [c] = candidates(src)
      assert List.last(c.ast_path) == 0
    end
  end

  describe "StatementDelete.mutate" do
    test "deletes the indexed statement, preserves the rest" do
      src = """
      defmodule M do
        def f(x) do
          IO.puts("a")
          IO.puts("b")
          x + 1
        end
      end
      """

      [c0, _c1] = candidates(src)

      [m] = StatementDelete.mutate(c0.node, ctx(c0.ast_path))
      # Mutated def's body has 2 statements (was 3), starting with IO.puts("b").
      assert {:def, _, [_head, [do: {:__block__, _, [first, _last]}]]} = m.mutated_ast
      assert {{:., _, [{:__aliases__, _, [:IO]}, :puts]}, _, ["b"]} = first
      assert m.mutation_kind == :statement_delete
      refute StatementDelete.equivalent?(m)
    end

    test "not applicable in schema engine or on non-def nodes" do
      src = """
      defmodule M do
        def f(x) do
          _ = side_effect(x)
          x + 1
        end
      end
      """

      [c] = candidates(src)
      schema_ctx = %{ctx(c.ast_path) | engine: :schema}
      refute StatementDelete.applicable?(c.node, schema_ctx)
      refute StatementDelete.applicable?({:+, [], [1, 2]}, ctx([0]))
    end
  end
end
