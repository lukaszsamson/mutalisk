defmodule Mut.EnvWalkerPatternLiteralTest do
  use ExUnit.Case, async: true

  @moduledoc """
  M53: literals in `:match` (pattern) positions are discovered with
  `env_context: :match` for the int/atom/boolean/nil/string subset, across
  bare args, list elements, and n-tuple elements. Bitstring segment literals
  are skipped (a `case`-free swap there can produce an invalid match), and
  body-position literals keep `env_context: nil`.
  """

  alias Mut.EnvWalker

  defp match_candidates(src) do
    {:ok, ast} = EnvWalker.parse_string(src, "lib/foo.ex")

    ast
    |> EnvWalker.collect_literal_candidates(file: "lib/foo.ex", source: src)
    |> Enum.filter(fn {candidate, _snap} -> candidate.env_context == :match end)
    |> Enum.map(fn {candidate, _snap} ->
      {:__block__, _, [value]} = candidate.node
      {candidate.syntactic_name, value}
    end)
  end

  test "bare argument, list, and n-tuple pattern literals are discovered as :match" do
    src = ~S'''
    defmodule Foo do
      def a(42), do: :ok
      def b([1, "two"]), do: :ok
      def c({:tag, 7, "x"}), do: :ok
      def e(true), do: :ok
    end
    '''

    assert match_candidates(src) == [
             {:__integer_literal__, 42},
             {:__integer_literal__, 1},
             {:__string_literal__, "two"},
             {:__atom_literal__, :tag},
             {:__integer_literal__, 7},
             {:__string_literal__, "x"},
             {:__boolean_literal__, true}
           ]
  end

  test "bitstring segment-size literals in patterns are skipped" do
    src = ~S'''
    defmodule Foo do
      def d(<<n::16>>), do: n
    end
    '''

    assert match_candidates(src) == []
  end

  test "float pattern literals are out of the M53 subset" do
    src = ~S'''
    defmodule Foo do
      def f(1.5), do: :ok
    end
    '''

    assert match_candidates(src) == []
  end

  test "body-position literals stay env_context nil (schema-routed)" do
    src = ~S'''
    defmodule Foo do
      def g, do: :ok
    end
    '''

    {:ok, ast} = EnvWalker.parse_string(src, "lib/foo.ex")

    body =
      ast
      |> EnvWalker.collect_literal_candidates(file: "lib/foo.ex", source: src)
      |> Enum.map(fn {candidate, _snap} -> candidate.env_context end)

    assert body == [nil]
  end
end
