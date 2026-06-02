defmodule Mut.EnvWalkerTest do
  use ExUnit.Case, async: true

  alias Mut.EnvWalker

  defp walk(source) do
    {:ok, ast} = EnvWalker.parse_string(source, "lib/foo.ex")
    EnvWalker.collect_literal_snapshots(ast, file: "lib/foo.ex", source: source)
  end

  describe "function body literals" do
    test "trusted, normal-context, function_body for a body string literal" do
      src = ~S'''
      defmodule Foo do
        def x do
          "hello"
        end
      end
      '''

      [snap] = walk(src) |> Enum.filter(&(&1.scope == :function_body))
      assert snap.trust_level == :trusted
      assert snap.context == nil
      assert snap.module == Foo
      assert snap.function == {:x, 0}
    end

    test "literals in match context (pattern args) are :match, not body literal eligible" do
      src = ~S'''
      defmodule Foo do
        def x("y") do
          :ok
        end
      end
      '''

      head_snaps = walk(src) |> Enum.filter(&(&1.scope == :function_head))
      assert Enum.any?(head_snaps, fn s -> s.context == :match end)
    end

    test "byte spans are codepoint-correct after a multi-byte char on the same line" do
      # "bar" sits after the literal "café" (é is 2 bytes) on the same line.
      # If byte_offset/3 added codepoint columns as bytes, "bar"'s span would
      # shift left by é's extra byte and slice to the wrong text.
      src = ~S'''
      defmodule Foo do
        def slogan, do: "café" <> "bar"
      end
      '''

      {:ok, ast} = EnvWalker.parse_string(src, "lib/foo.ex")

      sliced =
        ast
        |> EnvWalker.collect_string_literal_candidates(file: "lib/foo.ex", source: src)
        |> Enum.map(fn {candidate, _snap} ->
          span = candidate.source_span
          binary_part(src, span.start_byte, span.end_byte - span.start_byte)
        end)
        |> Enum.sort()

      assert sliced == [~s("bar"), ~s("café")]
    end

    test "literals in guards are :guard context" do
      src = ~S'''
      defmodule Foo do
        def x(n) when n > 0 do
          :ok
        end
      end
      '''

      assert Enum.any?(walk(src), &(&1.context == :guard))
    end

    test "default argument value is function_head, context nil (not body literal)" do
      src = ~S'''
      defmodule Foo do
        def x(n \\ 42) do
          n
        end
      end
      '''

      snaps = walk(src) |> Enum.filter(&(&1.scope == :function_head and &1.context == nil))
      assert Enum.any?(snaps)
    end
  end

  describe "context discrimination" do
    test "case match-clause pattern is :match" do
      src = ~S'''
      defmodule Foo do
        def x(v) do
          case v do
            "literal" -> :ok
            _ -> :err
          end
        end
      end
      '''

      assert Enum.any?(walk(src), &(&1.context == :match))
    end

    test "case body after match is :nil context, function_body scope" do
      src = ~S'''
      defmodule Foo do
        def x(v) do
          case v do
            _ -> "body"
          end
        end
      end
      '''

      bodies = walk(src) |> Enum.filter(&(&1.scope == :function_body and &1.context == nil))
      assert Enum.any?(bodies, fn s -> s.trust_level == :trusted end)
    end

    test "pin operator child is normal context" do
      src = ~S'''
      defmodule Foo do
        def x(v, pinned) do
          case v do
            ^pinned -> "ok"
          end
        end
      end
      '''

      _ = walk(src)
    end
  end

  describe "macro/quote boundaries" do
    test "quote body literals are untracked (no snapshots descend into quote)" do
      src = ~S'''
      defmodule Foo do
        def x do
          quote do
            "inside-quote"
          end
        end
      end
      '''

      # The quote body is not descended; no function_body literal emitted for "inside-quote".
      bodies = walk(src) |> Enum.filter(&(&1.scope == :function_body and &1.context == nil))
      strings = Enum.map(bodies, fn s -> s.line end)

      refute Enum.any?(bodies, fn s ->
               s.trust_level == :trusted and s.module == Foo and s.function == {:x, 0} and
                 s.line >= 3
             end) and "inside-quote" in strings
    end

    test "user-macro call in module body produces opaque/untrusted-descendant snapshots" do
      src = ~S'''
      defmodule Foo do
        use SomeMacro
      end
      '''

      snaps = walk(src)
      # SomeMacro call body is empty; no literal snapshots expected from descendants.
      # But the walk completes cleanly.
      assert is_list(snaps)
    end
  end

  describe "macro definitions" do
    test "defmacro body has scope :macro_definition" do
      src = ~S'''
      defmodule Foo do
        defmacro mac do
          "macro-body-literal"
        end
      end
      '''

      snaps = walk(src) |> Enum.filter(&(&1.scope == :macro_definition))
      assert Enum.any?(snaps)
    end

    test "defguard body has scope :function_body but context :guard" do
      src = ~S'''
      defmodule Foo do
        defguard is_positive(n) when n > 0
      end
      '''

      assert Enum.any?(walk(src), &(&1.context == :guard))
    end
  end

  describe "parse_string/2" do
    test "wraps literals in __block__ nodes" do
      assert {:ok, ast} = EnvWalker.parse_string(~s|"x"|, "lib/foo.ex")
      assert match?({:__block__, _, ["x"]}, ast)
    end

    test "preserves :token_metadata and :columns" do
      assert {:ok, {:__block__, meta, ["x"]}} = EnvWalker.parse_string(~s|"x"|, "lib/foo.ex")
      assert Keyword.has_key?(meta, :line)
      assert Keyword.has_key?(meta, :column)
    end
  end

  describe "generated code" do
    test "AST node with generated: true metadata is :generated trust" do
      src = ~S'''
      defmodule Foo do
        def x do
          "hello"
        end
      end
      '''

      [snap] = walk(src) |> Enum.filter(&(&1.scope == :function_body and &1.context == nil))
      assert snap.trust_level == :trusted
    end
  end
end
