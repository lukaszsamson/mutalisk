defmodule Mut.Mutator.MapUpdateDropTest do
  use ExUnit.Case, async: true

  @moduledoc "M94 MapUpdateDrop + AstWalk.map_update_drop_candidates."

  alias Mut.AstWalk
  alias Mut.Context
  alias Mut.Mutator.MapUpdateDrop

  defp candidates(src) do
    ast = Code.string_to_quoted!(src, columns: true, token_metadata: true)
    AstWalk.map_update_drop_candidates(ast, file: "m.ex", source: src)
  end

  defp ctx(ast_path),
    do: %Context{engine: :fallback, file: "m.ex", ast_path: ast_path, ast_path_hash: "h"}

  describe "metadata" do
    test "name/targets" do
      assert MapUpdateDrop.name() == "MapUpdateDrop"
      assert MapUpdateDrop.targets() == [:map_update_drop]
    end
  end

  describe "AstWalk.map_update_drop_candidates" do
    test "skips plain map literals (no update pipe)" do
      src = """
      defmodule M do
        def f, do: %{a: 1, b: 2}
      end
      """

      assert candidates(src) == []
    end

    test "emits one candidate per `%{m | …}` update" do
      src = """
      defmodule M do
        def f(m, v) do
          %{m | k: v, a: 1}
        end
      end
      """

      cands = candidates(src)
      assert length(cands) == 1
      [c] = cands
      assert c.syntactic_name == :map_update_drop
    end

    test "emits multiple candidates for multiple updates in the same function" do
      src = """
      defmodule M do
        def f(m, v) do
          x = %{m | k: v}
          %{x | a: 1}
        end
      end
      """

      assert length(candidates(src)) == 2
    end
  end

  describe "MapUpdateDrop.mutate" do
    test "mutation drops the update, returns the base" do
      src = """
      defmodule M do
        def f(m, v) do
          %{m | k: v, a: 1}
        end
      end
      """

      [c] = candidates(src)
      [mu] = MapUpdateDrop.mutate(c.node, ctx(c.ast_path))

      rendered = Macro.to_string(mu.mutated_ast)
      assert rendered == "m"
    end

    test "not applicable in schema engine or on non-update maps" do
      src = """
      defmodule M do
        def f(m, v) do
          %{m | k: v}
        end
      end
      """

      [c] = candidates(src)
      schema_ctx = %{ctx(c.ast_path) | engine: :schema}
      refute MapUpdateDrop.applicable?(c.node, schema_ctx)
      refute MapUpdateDrop.applicable?({:%{}, [], [a: 1]}, ctx([0]))
    end
  end
end
