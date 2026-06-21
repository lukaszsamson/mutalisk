defmodule Mut.AstWalkTest do
  use ExUnit.Case, async: true

  @moduledoc false

  test "emits binary operator candidates" do
    assert [%{syntactic_name: :+, syntactic_arity: 2}] = candidates("1 + 2")
  end

  test "emits unary operator candidates" do
    assert [%{syntactic_name: :not, syntactic_arity: 1}] = candidates("not x")
  end

  test "emits local call candidates" do
    assert [%{syntactic_name: :foo, syntactic_arity: 2}] = candidates("foo(a, b)")
  end

  test "emits remote call candidates" do
    assert [%{syntactic_name: :bar, syntactic_arity: 1}] = candidates("Mod.bar(x)")
  end

  test "skips pipe and capture nodes while descending into pipe children" do
    found = candidates("x |> Enum.map(&f/1)")

    refute Enum.any?(found, &(&1.syntactic_name == :|>))
    refute Enum.any?(found, &(&1.syntactic_name == :&))
    assert Enum.any?(found, &(&1.syntactic_name == :map and &1.syntactic_arity == 2))
  end

  test "skips module attribute reads" do
    assert [] = candidates("@foo")
  end

  test "skips module attribute bodies" do
    assert [] = candidates("@moduledoc \"docs\"")
    assert [] = candidates("@some_const 1")
  end

  test "skips guarded function heads" do
    found = candidates("def positive?(x) when is_integer(x) and x > 0, do: x")

    refute Enum.any?(found, &(&1.syntactic_name == :positive?))
    assert Enum.any?(found, &(&1.syntactic_name == :is_integer))
    assert Enum.any?(found, &(&1.syntactic_name == :and))
    assert Enum.any?(found, &(&1.syntactic_name == :>))
  end

  test "skips variables" do
    assert [] = candidates("x")
  end

  test "skips special form nodes and emits dispatches inside" do
    case_candidates = candidates("case x do\n  1 -> foo(x)\nend")
    if_candidates = candidates("if cond, do: foo(a), else: bar(b)")
    for_candidates = candidates("for x <- list, do: f.(x)")

    refute Enum.any?(case_candidates, &(&1.syntactic_name == :case))
    assert Enum.any?(case_candidates, &(&1.syntactic_name == :foo))

    refute Enum.any?(if_candidates, &(&1.syntactic_name == :if))
    assert Enum.any?(if_candidates, &(&1.syntactic_name == :foo))
    assert Enum.any?(if_candidates, &(&1.syntactic_name == :bar))

    refute Enum.any?(for_candidates, &(&1.syntactic_name == :for))
    assert Enum.any?(for_candidates, &(&1.syntactic_name == :<-))
    assert Enum.any?(for_candidates, &(&1.syntactic_name == :f))
  end

  test "skips quote family blocks without descending" do
    assert [] = candidates("quote do\n  foo(1)\nend")
  end

  test "computes byte offsets on multi-byte source" do
    source = "def naïve_add(a, b), do: foo(a)\n"
    [candidate] = candidates(source)

    assert candidate.syntactic_name == :foo
    assert candidate.source_span.start_byte == :binary.match(source, "foo") |> elem(0)
  end

  test "ast path hash is stable across runs" do
    first = candidates("foo(1 + 2)")
    second = candidates("foo(1 + 2)")

    assert Enum.map(first, & &1.ast_path_hash) == Enum.map(second, & &1.ast_path_hash)
    assert Enum.all?(first, &(String.length(&1.ast_path_hash) == 32))
  end

  test "map_update_drop fires on a plain map update but NOT a struct update (R8)" do
    assert [_] = map_update_candidates("def f(m), do: %{m | a: 1}")
    assert [] == map_update_candidates("def f(s), do: %State{s | a: 1}")
  end

  test "pipeline_drop does not crash on a dynamic defmodule (R18)" do
    source = """
    defmodule unquote(name) do
      def f(x), do: x |> a() |> b() |> c() |> d()
    end
    """

    assert is_list(pipeline_candidates(source))
  end

  test "guard candidates fire inside an n-ary fn `when` clause (R12)" do
    # `fn x, acc when is_integer(x) -> ...` is `{:when, _, [x, acc, guard]}`;
    # the guard dispatch (`is_integer/1`) must still be discovered.
    source = "f = fn x, acc when is_integer(x) -> acc end"
    assert {:ok, ast} = Mut.SourceParse.parse_string(source, "sample.ex")
    guards = Mut.AstWalk.guard_candidates(ast, file: "sample.ex", source: source)

    assert Enum.any?(guards, &(&1.syntactic_name == :is_integer))
  end

  test "StatementDelete skips a statement that is the sole reader of a param (T4)" do
    # Deleting `y = x + 1` would leave param `x` unused → unused-variable warning
    # → invalid under --warnings-as-errors. The hazard must gate it.
    source = """
    def f(x) do
      y = x + 1
      y * 2
    end
    """

    refute Enum.any?(statement_delete(source), &(&1.syntactic_name == :statement_delete))
  end

  test "charlist collection span covers the whole literal, not one byte (T1)" do
    source = ~S"""
    def f do
      x = 'abc'
      x
    end
    """

    [cand] =
      collection_candidates(source)
      |> Enum.filter(&(&1.syntactic_name == :__list_literal__))

    span = cand.source_span
    assert binary_part(source, span.start_byte, span.end_byte - span.start_byte) == "'abc'"
  end

  test "receive/after timeout literal is not an env-walker literal candidate (T5)" do
    source = """
    def f do
      receive do
        :msg -> :ok
      after
        1000 -> :timeout
      end
    end
    """

    # The `1000` timeout belongs to ReceiveTimeout (M94); the env walker must not
    # also emit it as a literal candidate (it previously did, in match context,
    # duplicating the mutant under a different stable id).
    refute Enum.any?(env_candidates(source), fn {c, _snap} ->
             match?({:__block__, _, [1000]}, c.node)
           end)
  end

  test "fallback candidates in a nested module carry the fully-qualified enclosing_module (R11)" do
    source = """
    defmodule Outer do
      defmodule Inner do
        def f(x) do
          IO.puts("side effect")
          x - 1
        end
      end

      def g(y) do
        IO.puts("outer")
        y + 1
      end
    end
    """

    cands = statement_delete(source)
    modules = cands |> Enum.map(& &1.enclosing_module) |> Enum.uniq()

    # Inner's candidate must be attributed to `Outer.Inner`, not the bare
    # `Inner` — otherwise it never matches `ignored_modules/1` (which qualifies)
    # and `@mutalisk_ignore` in a nested module is silently ignored.
    assert Outer.Inner in modules
    assert Outer in modules
    refute Inner in modules
  end

  test "pipeline-drop candidates in a nested module also carry the qualified module (R11)" do
    source = """
    defmodule Outer do
      defmodule Inner do
        def f(x) do
          x |> Map.put(:a, 1) |> Map.put(:b, 2) |> Map.put(:c, 3)
        end
      end
    end
    """

    modules =
      source
      |> pipeline_candidates()
      |> Enum.map(& &1.enclosing_module)
      |> Enum.uniq()

    assert Outer.Inner in modules
    refute Inner in modules
  end

  defp candidates(source) do
    assert {:ok, ast} = Mut.SourceParse.parse_string(source, "sample.ex")
    Mut.AstWalk.dispatch_candidates(ast, file: "sample.ex", source: source)
  end

  defp statement_delete(source) do
    assert {:ok, ast} = Mut.SourceParse.parse_string(source, "sample.ex")
    Mut.AstWalk.statement_delete_candidates(ast, file: "sample.ex", source: source)
  end

  defp collection_candidates(source) do
    env_candidates(source) |> Enum.map(fn {cand, _snap} -> cand end)
  end

  defp env_candidates(source) do
    {:ok, ast} = Mut.EnvWalker.parse_string(source, "sample.ex")
    Mut.EnvWalker.collect_literal_candidates(ast, file: "sample.ex", source: source)
  end

  defp map_update_candidates(source) do
    assert {:ok, ast} = Mut.SourceParse.parse_string(source, "sample.ex")
    Mut.AstWalk.map_update_drop_candidates(ast, file: "sample.ex", source: source)
  end

  defp pipeline_candidates(source) do
    assert {:ok, ast} = Mut.SourceParse.parse_string(source, "sample.ex")
    Mut.AstWalk.pipeline_drop_candidates(ast, file: "sample.ex", source: source)
  end
end
