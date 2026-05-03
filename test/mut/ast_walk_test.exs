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

  defp candidates(source) do
    assert {:ok, ast} = Mut.SourceParse.parse_string(source, "sample.ex")
    Mut.AstWalk.dispatch_candidates(ast, file: "sample.ex", source: source)
  end
end
