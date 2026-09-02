defmodule Mut.AstWalk.AttributeCandidatesTest do
  use ExUnit.Case, async: true

  @moduledoc false

  test "emits literal module attribute definitions" do
    assert [candidate] = candidates("defmodule M do\n  @some_const 42\nend\n")
    assert candidate.syntactic_name == :some_const
    assert candidate.syntactic_arity == 0
    assert candidate.env_context == nil
    assert candidate.enclosing_module == M
    assert candidate.node == 42
    assert candidate.source_span.start_line == 2
  end

  test "skips reserved attributes" do
    source = """
    defmodule M do
      @moduledoc "docs"
      @spec f() :: atom()
      @behaviour GenServer
    end
    """

    assert [] = candidates(source)
  end

  test "skips non-literal values" do
    source = """
    defmodule M do
      @cfg Application.compile_env(:app, :key)
    end
    """

    assert [] = candidates(source)
  end

  test "skips attribute reads inside functions" do
    source = """
    defmodule M do
      @some_const 42
      def f, do: @some_const
    end
    """

    assert [%{syntactic_name: :some_const}] = candidates(source)
  end

  test "skips attribute definitions inside functions" do
    source = """
    defmodule M do
      def f do
        @scoped 1
      end
    end
    """

    assert [] = candidates(source)
  end

  test "emits nested enclosing module" do
    source = "defmodule Outer.Inner do\n  @some_const 42\nend\n"

    assert [%{enclosing_module: Outer.Inner}] = candidates(source)
  end

  # M108: cover the collection branches of the literal? classifier — a list,
  # an n-tuple (`{:{}, ...}`), and a map are all literal-valued attributes.
  test "emits collection-literal attributes (list / n-tuple / map)" do
    assert [%{node: [1, 2, 3]}] = candidates("defmodule M do\n  @c [1, 2, 3]\nend\n")
    assert [%{node: {:{}, _, [1, 2, 3]}}] = candidates("defmodule M do\n  @c {1, 2, 3}\nend\n")

    assert [%{node: {:%{}, _, [a: 1, b: 2]}}] =
             candidates("defmodule M do\n  @c %{a: 1, b: 2}\nend\n")
  end

  test "skips collections containing a non-literal element" do
    assert [] = candidates("defmodule M do\n  @c [foo()]\nend\n")
  end

  # A bare 2-tuple is not classified literal (only `{:{}, ...}` n-tuples are),
  # so it is skipped — guards the classifier's catch-all clause.
  test "skips a bare two-tuple attribute" do
    assert [] = candidates("defmodule M do\n  @c {1, 2}\nend\n")
  end

  # B12/D3: the span used `end_of_expression[:column]` with the attribute's
  # START line, so a multi-line value produced an inverted (or truncated) range.
  test "spans a multi-line attribute value to its last line" do
    source = "defmodule M do\n  @opts [\n    1,\n    2\n  ]\nend\n"

    assert [%{syntactic_name: :opts, source_span: span}] = candidates(source)
    assert span.start_line == 2
    assert span.end_line == 5
    assert span.start_byte < span.end_byte

    assert binary_part(source, span.start_byte, span.end_byte - span.start_byte) ==
             "[\n    1,\n    2\n  ]"
  end

  # Stable ids include `end_byte`: single-line attribute spans must not move.
  test "single-line attribute span is unchanged" do
    source = "defmodule M do\n  @c [1, 2]\nend\n"

    assert [%{source_span: span}] = candidates(source)
    assert span.start_line == 2
    assert span.end_line == 2
    assert span.start_column == 6
    assert span.end_column == 12
    assert span.start_byte == 20
    assert span.end_byte == 26
    assert binary_part(source, span.start_byte, span.end_byte - span.start_byte) == "[1, 2]"
  end

  defp candidates(source) do
    assert {:ok, ast} = Mut.SourceParse.parse_string(source, "sample.ex")
    Mut.AstWalk.attribute_candidates(ast, file: "sample.ex", source: source)
  end
end
