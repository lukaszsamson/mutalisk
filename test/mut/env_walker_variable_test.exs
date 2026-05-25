defmodule Mut.EnvWalkerVariableTest do
  use ExUnit.Case, async: true

  @moduledoc """
  M54: `collect_variable_candidates/2` emits in-scope variable *reads* in
  trusted function bodies, with `bound_vars` listing the in-scope
  alternatives (function params + enclosing clause-head bindings).
  """

  alias Mut.EnvWalker

  defp vars(src) do
    {:ok, ast} = EnvWalker.parse_string(src, "lib/foo.ex")

    ast
    |> EnvWalker.collect_variable_candidates(file: "lib/foo.ex", source: src)
    |> Enum.map(fn {candidate, _snap} ->
      {name, _meta, _ctx} = candidate.node
      {name, candidate.bound_vars}
    end)
  end

  test "function-body reads carry their in-scope alternatives" do
    src = ~S'''
    defmodule Foo do
      def add(a, b) do
        a + b
      end
    end
    '''

    assert vars(src) == [{:a, [:b]}, {:b, [:a]}]
  end

  test "a sole binding yields no candidate (no alternative to swap to)" do
    src = ~S'''
    defmodule Foo do
      def solo(n), do: n
    end
    '''

    assert vars(src) == []
  end

  test "clause-head bindings extend scope inside the clause body" do
    src = ~S'''
    defmodule Foo do
      def pick(x) do
        case x do
          {:ok, v} -> v
          _ -> x
        end
      end
    end
    '''

    # `v` read sees {x, v} minus self -> [:x]; `x` read sees {x} minus self ->
    # no alternative, so only the `case x` scrutinee read (alts [] -> skipped)
    # and the `v` body read survive.
    assert vars(src) == [{:v, [:x]}]
  end

  test "underscore-prefixed and pinned names are neither bound nor swapped" do
    src = ~S'''
    defmodule Foo do
      def f(a, _b) do
        a
      end
    end
    '''

    # `_b` is not a swap alternative, so `a` (sole real binding) has none.
    assert vars(src) == []
  end

  test "bitstring segment specifiers are not treated as bindings or swap targets" do
    # `<<original::bits>>` — `bits` is a type specifier, AST-shaped as a
    # variable, but must never be collected as a binding or offered as a swap
    # target (doing so produces undefined-variable mutants). Reads *inside* a
    # bitstring are also skipped.
    src = ~S'''
    defmodule Foo do
      def parse(<<original::bits>>, len) do
        decode(original, len)
      end
    end
    '''

    assert vars(src) == [{:original, [:len]}, {:len, [:original]}]
  end

  test "default-argument expressions are not collected as bindings (@attr, calls)" do
    # `timeout \\ @default_timeout` — `default_timeout` (the attribute name
    # stripped of `@`) must NOT become a swap target; a bare `default_timeout`
    # in the body is an undefined variable. Only `req`/`timeout` bind.
    src = ~S'''
    defmodule Foo do
      @default_timeout 5000
      def call(req, timeout \\ @default_timeout) do
        send(req, timeout)
      end
    end
    '''

    assert vars(src) == [{:req, [:timeout]}, {:timeout, [:req]}]
  end

  test "guard variables in multi-arg clause heads are not collected" do
    src = ~S'''
    defmodule Foo do
      def run(a, b) do
        f = fn x, y when x > limit -> x + y + a + b end
        f.(a, b)
      end
    end
    '''

    # No `:limit` (guard ref) anywhere in the alternative sets.
    refute Enum.any?(vars(src), fn {_name, alts} -> :limit in alts end)
  end

  test "type-determining operators hint their direct variable operands (M56)" do
    src = ~S'''
    defmodule Foo do
      def calc(a, b), do: a + b
      def cat(s, t), do: s <> t
      def merge(xs, ys), do: xs ++ ys
      def viacall(p, q), do: g(p) + q
    end
    '''

    {:ok, ast} = EnvWalker.parse_string(src, "lib/foo.ex")

    hints =
      ast
      |> EnvWalker.collect_variable_candidates(file: "lib/foo.ex", source: src)
      |> Enum.map(fn {c, _} -> {elem(c.node, 0), c.type_hint} end)

    # a/b numeric, s/t binary, xs/ys list; `g(p)` is a call (not a direct
    # operand) so `p` is NOT hinted; `q` is a direct numeric operand.
    assert {:a, :number} in hints
    assert {:s, :binary} in hints
    assert {:xs, :list} in hints
    assert {:p, nil} in hints
    assert {:q, :number} in hints
  end

  test "local type-functions and boolean operators hint their variable args (M56)" do
    src = ~S'''
    defmodule Foo do
      def f(a, s, xs, flag, other) do
        {abs(a), byte_size(s), length(xs), flag and other}
      end
    end
    '''

    {:ok, ast} = EnvWalker.parse_string(src, "lib/foo.ex")

    hints =
      ast
      |> EnvWalker.collect_variable_candidates(file: "lib/foo.ex", source: src)
      |> Enum.map(fn {c, _} -> {elem(c.node, 0), c.type_hint} end)

    assert {:a, :number} in hints
    assert {:s, :binary} in hints
    assert {:xs, :list} in hints
    assert {:flag, :boolean} in hints
    assert {:other, :boolean} in hints
  end

  test "function names in pipe-rhs / named-capture position are not variables" do
    src = ~S'''
    defmodule Foo do
      def f(filename, items, mapper) do
        a = filename |> to_string
        b = Enum.map(items, &handle/1)
        c = items |> Enum.map(mapper)
        {a, b, c}
      end
      def handle(i), do: i
    end
    '''

    {:ok, ast} = EnvWalker.parse_string(src, "lib/foo.ex")

    names =
      ast
      |> EnvWalker.collect_variable_candidates(file: "lib/foo.ex", source: src)
      |> Enum.map(fn {c, _} -> elem(c.node, 0) end)

    # `to_string` (pipe-rhs fn) and `handle` (captured fn) must NOT appear;
    # real piped variables must.
    refute :to_string in names
    refute :handle in names
    assert :filename in names
    assert :items in names
  end

  test "M57: codegen functions (quote/unquote bodies) emit no variable candidates" do
    src = ~S'''
    defmodule Foo do
      def gen(x, y) do
        quote do
          unquote(x) + unquote(y)
        end
      end
      def plain(a, b), do: a + b + a
    end
    '''

    {:ok, ast} = EnvWalker.parse_string(src, "lib/foo.ex")

    fns =
      ast
      |> EnvWalker.collect_variable_candidates(file: "lib/foo.ex", source: src)
      |> Enum.map(fn {_c, snap} -> elem(snap.function, 0) end)
      |> Enum.uniq()

    assert fns == [:plain]
  end

  test "M57: other_uses? marks names with >=1 other read in the same function" do
    src = ~S'''
    defmodule Foo do
      def f(a, b) do
        a + b + a
      end
    end
    '''

    {:ok, ast} = EnvWalker.parse_string(src, "lib/foo.ex")

    marks =
      ast
      |> EnvWalker.collect_variable_candidates(file: "lib/foo.ex", source: src)
      |> Enum.map(fn {c, _} -> {elem(c.node, 0), c.other_uses?} end)

    # `a` read twice -> true (both occurrences); `b` read once -> false.
    assert {:a, true} in marks
    assert {:b, false} in marks
    refute {:a, false} in marks
  end

  test "variable candidates have env_context nil (reads)" do
    src = ~S'''
    defmodule Foo do
      def add(a, b), do: a + b
    end
    '''

    {:ok, ast} = EnvWalker.parse_string(src, "lib/foo.ex")
    pairs = EnvWalker.collect_variable_candidates(ast, file: "lib/foo.ex", source: src)
    assert Enum.all?(pairs, fn {c, _snap} -> c.env_context == nil end)
  end
end
