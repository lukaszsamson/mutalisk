defmodule Mut.AstWalk.GuardCandidatesTest do
  use ExUnit.Case, async: true

  @moduledoc false

  test "emits comparison candidate from function guards" do
    assert [%{syntactic_name: :>, syntactic_arity: 2, env_context: :guard}] =
             candidates("defmodule M do\n  def f(x) when x > 0, do: x\nend\n")
  end

  test "emits enclosing module for fallback metadata" do
    assert [%{syntactic_name: :>, enclosing_module: M}] =
             candidates("defmodule M do\n  def f(x) when x > 0, do: x\nend\n")
  end

  test "emits all dispatches from compound guards" do
    found = candidates("defmodule M do\n  def f(x) when is_integer(x) and x > 0, do: x\nend\n")

    assert Enum.map(found, & &1.syntactic_name) == [:is_integer, :and, :>]
    assert Enum.all?(found, &(&1.env_context == :guard))
  end

  test "uses precise fallback spans for same-line guard dispatches" do
    source = "defmodule M do\n  def f(x) when is_integer(x) and x > 0, do: x\nend\n"

    assert [is_integer, and_op, gt] = candidates(source)

    assert span_text(source, is_integer.source_span) == "is_integer(x)"
    assert span_text(source, and_op.source_span) == "is_integer(x) and x > 0"
    assert span_text(source, gt.source_span) == "x > 0"
  end

  test "emits case clause guards" do
    source = """
    defmodule M do
      def f(x) do
        case x do
          y when y > 0 -> y
          y -> y
        end
      end
    end
    """

    assert [%{syntactic_name: :>}] = candidates(source)
  end

  test "emits anonymous function clause guards" do
    source = "defmodule M do\n  def f, do: fn x when x > 0 -> x end\nend\n"

    assert [%{syntactic_name: :>}] = candidates(source)
  end

  test "does not emit function body operators" do
    source = "defmodule M do\n  def f(x), do: x > 0\nend\n"

    assert [] = candidates(source)
  end

  defp candidates(source) do
    assert {:ok, ast} = Mut.SourceParse.parse_string(source, "sample.ex")
    Mut.AstWalk.guard_candidates(ast, file: "sample.ex", source: source)
  end

  defp span_text(source, span) do
    binary_part(source, span.start_byte, span.end_byte - span.start_byte)
  end
end
