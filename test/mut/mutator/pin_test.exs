defmodule Mut.Mutator.PinTest do
  use ExUnit.Case, async: true

  @moduledoc "M73 pattern-shape: Pin (unpin ^x -> x) + AstWalk.pin_candidates."

  alias Mut.AstWalk
  alias Mut.Context
  alias Mut.Mutator.Pin
  alias Mut.Oracle.AstCandidate

  @source """
  defmodule M do
    def f(x, y) do
      case y do
        ^x -> :match
        _ -> :no
      end
    end
  end
  """

  defp ast, do: Code.string_to_quoted!(@source, columns: true, token_metadata: true)

  describe "metadata" do
    test "name/description/targets" do
      assert Pin.name() == "Pin"
      assert Pin.targets() == [:pattern_shape]
    end
  end

  describe "AstWalk.pin_candidates" do
    test "finds the ^x pin with a span covering the whole `^x`" do
      [candidate] = AstWalk.pin_candidates(ast(), file: "m.ex", source: @source)

      assert %AstCandidate{syntactic_name: :^, env_context: :match} = candidate
      span = candidate.source_span
      sliced = binary_part(@source, span.start_byte, span.end_byte - span.start_byte)
      assert sliced == "^x"
    end

    test "no candidates when there are no pins" do
      src = "defmodule N do\n  def g(a), do: a + 1\nend\n"
      ast = Code.string_to_quoted!(src, columns: true, token_metadata: true)
      assert AstWalk.pin_candidates(ast, file: "n.ex", source: src) == []
    end
  end

  describe "Pin.mutate" do
    setup do
      [candidate] = AstWalk.pin_candidates(ast(), file: "m.ex", source: @source)
      {:ok, node: candidate.node}
    end

    test "unpins ^x -> x in a fallback :match context", %{node: node} do
      ctx = %Context{
        engine: :fallback,
        env_context: :match,
        file: "m.ex",
        ast_path: [],
        ast_path_hash: 0
      }

      [mutation] = Pin.mutate(node, ctx)

      assert {:x, _meta, ctx_atom} = mutation.mutated_ast
      assert is_atom(ctx_atom)
      assert mutation.mutation_kind == :pin_removal
      assert mutation.guard_safe?
      refute Pin.equivalent?(mutation)
    end

    test "not applicable outside fallback / match / pin", %{node: node} do
      refute Pin.applicable?(node, %Context{
               engine: :schema,
               env_context: :match,
               file: "m.ex",
               ast_path: [],
               ast_path_hash: 0
             })

      refute Pin.applicable?(node, %Context{
               engine: :fallback,
               env_context: nil,
               file: "m.ex",
               ast_path: [],
               ast_path_hash: 0
             })

      refute Pin.applicable?(
               {:+, [], [1, 2]},
               %Context{
                 engine: :fallback,
                 env_context: :match,
                 file: "m.ex",
                 ast_path: [],
                 ast_path_hash: 0
               }
             )
    end
  end
end
