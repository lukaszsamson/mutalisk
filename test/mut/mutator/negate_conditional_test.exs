defmodule Mut.Mutator.NegateConditionalTest do
  use ExUnit.Case, async: true

  @moduledoc "M77 NegateConditional + AstWalk.conditional_candidates."

  alias Mut.AstWalk
  alias Mut.Context
  alias Mut.Mutator.NegateConditional

  @source """
  defmodule M do
    def f(x) do
      if x > 0 do
        :pos
      else
        :neg
      end
    end

    def g(y), do: unless(y, do: :ok)
  end
  """

  defp ast, do: Code.string_to_quoted!(@source, columns: true, token_metadata: true)
  defp ctx, do: %Context{engine: :fallback, file: "m.ex", ast_path: [], ast_path_hash: 0}

  describe "AstWalk.conditional_candidates" do
    test "finds the block-form if, span covers the whole if...end" do
      cands = AstWalk.conditional_candidates(ast(), file: "m.ex", source: @source)
      # Only the block-form `if` (the keyword-form `unless(y, do: …)` has no :end).
      assert [c] = cands
      assert c.syntactic_name == :if
      span = c.source_span
      sliced = binary_part(@source, span.start_byte, span.end_byte - span.start_byte)
      assert String.starts_with?(sliced, "if x > 0 do")
      assert String.ends_with?(sliced, "end")
    end
  end

  describe "NegateConditional.mutate" do
    setup do
      [c] = AstWalk.conditional_candidates(ast(), file: "m.ex", source: @source)
      {:ok, node: c.node}
    end

    test "produces negate + force true + force false, preserving branches", %{node: node} do
      mutations = NegateConditional.mutate(node, ctx())
      assert length(mutations) == 3

      changes = Enum.map(mutations, & &1.metadata.change)
      assert changes == ["negate", "force true", "force false"]

      [neg, ft, ff] = mutations
      assert {:if, _, [{:not, _, [_cond]}, kw]} = neg.mutated_ast
      assert Keyword.has_key?(kw, :do) and Keyword.has_key?(kw, :else)
      assert {:if, _, [true, _kw]} = ft.mutated_ast
      assert {:if, _, [false, _kw]} = ff.mutated_ast
      assert Enum.all?(mutations, &(NegateConditional.equivalent?(&1) == false))
    end

    test "not applicable in schema engine or on non-conditional nodes", %{node: node} do
      refute NegateConditional.applicable?(node, %Context{
               engine: :schema,
               file: "m.ex",
               ast_path: [],
               ast_path_hash: 0
             })

      refute NegateConditional.applicable?({:+, [], [1, 2]}, ctx())
    end
  end
end
