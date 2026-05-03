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

  defp candidates(source) do
    assert {:ok, ast} = Mut.SourceParse.parse_string(source, "sample.ex")
    Mut.AstWalk.attribute_candidates(ast, file: "sample.ex", source: source)
  end
end
