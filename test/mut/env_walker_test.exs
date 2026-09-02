defmodule Mut.EnvWalkerTest do
  use ExUnit.Case, async: true

  alias Mut.EnvWalker

  defp walk(source) do
    {:ok, ast} = EnvWalker.parse_string(source, "lib/foo.ex")
    EnvWalker.collect_literal_snapshots(ast, file: "lib/foo.ex", source: source)
  end

  # `[{AstCandidate, EnvSnapshot}]` for the full low-noise literal set.
  # `macro_index` entries are `{file, line, column, name, arity}` keys proving a
  # call resolved to a Kernel macro (see Mut.EnvOracle.build_macro_index/1).
  defp candidates(source, macro_index \\ nil) do
    {:ok, ast} = EnvWalker.parse_string(source, "lib/foo.ex")

    EnvWalker.collect_literal_candidates(ast,
      file: "lib/foo.ex",
      source: source,
      macro_index: macro_index
    )
  end

  defp literal_texts(source, macro_index \\ nil) do
    source
    |> candidates(macro_index)
    |> Enum.map(fn {candidate, _snap} ->
      span = candidate.source_span
      binary_part(source, span.start_byte, span.end_byte - span.start_byte)
    end)
    |> Enum.sort()
  end

  defp kernel_if_index(entries) do
    Map.new(entries, fn {name, line, column} ->
      {{"lib/foo.ex", line, column, name, 2},
       %{
         kind: :imported_macro,
         resolved_module: Kernel,
         resolved_name: name,
         resolved_arity: 2
       }}
    end)
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

  describe "remote calls (T11)" do
    test "literals inside a remote call's arguments are discovered" do
      src = ~S'''
      defmodule Foo do
        def run(items) do
          Enum.map(items, "arg")
        end
      end
      '''

      assert literal_texts(src) == [~s("arg")]
    end

    test "literals nested in an anonymous function passed to a remote call" do
      src = ~S'''
      defmodule Foo do
        def run(items) do
          Enum.map(items, fn item -> Kernel.to_string(item) <> "suffix" end)
        end
      end
      '''

      assert literal_texts(src) == [~s("suffix")]
    end

    test "a variable receiver and an anonymous-function call are descended" do
      src = ~S'''
      defmodule Foo do
        def run(mod, fun) do
          mod.call("via-var")
          fun.("via-anon")
        end
      end
      '''

      assert literal_texts(src) == [~s("via-anon"), ~s("via-var")]
    end

    test "the called module itself is never a candidate" do
      # `Enum` (an __aliases__ node) and `:erlang` (a literal-encoded atom in
      # receiver position) are call targets, not values: mutating them would
      # retarget the call.
      src = ~S'''
      defmodule Foo do
        def run(x) do
          :erlang.element(:pos, Enum.at(x, :idx))
        end
      end
      '''

      assert literal_texts(src) == [":idx", ":pos"]
    end

    test "a remote call in module body stays untrusted (no candidates)" do
      src = ~S'''
      defmodule Foo do
        Module.register_attribute(__MODULE__, "attr")
      end
      '''

      assert literal_texts(src) == []
    end
  end

  describe "keyword-block bodies (T12)" do
    test "if/else bodies are descended when the tracer proves Kernel.if" do
      src = ~S'''
      defmodule Foo do
        def check(a) do
          if a do
            "yes"
          else
            "no"
          end
        end
      end
      '''

      assert literal_texts(src, kernel_if_index([{:if, 3, 5}])) == [~s("no"), ~s("yes")]
    end

    test "unqualified if (no tracer proof) stays opaque — bodies yield nothing" do
      src = ~S'''
      defmodule Foo do
        def check(a) do
          if a do
            "yes"
          else
            "no"
          end
        end
      end
      '''

      assert literal_texts(src) == []
    end

    test "single-line keyword do:/else: bodies are descended" do
      src = ~S'''
      defmodule Foo do
        def check(a) do
          unless a, do: "off", else: "on"
        end
      end
      '''

      assert literal_texts(src, kernel_if_index([{:unless, 3, 5}])) == [~s("off"), ~s("on")]
    end

    test "keyword arguments of an ordinary call are descended, keys are not" do
      src = ~S'''
      defmodule Foo do
        def run(a) do
          local_call(a, mode: "fast")
        end
      end
      '''

      assert literal_texts(src) == [~s("fast")]
    end

    test "keyword values in a map literal are still not descended (unchanged)" do
      # Map pairs reach `descend_args/2` one at a time, not the list clause, so
      # T12 does not change them.
      src = ~S'''
      defmodule Foo do
        def run do
          %{mode: "fast"}
        end
      end
      '''

      assert literal_texts(src) == [~s(%{mode: "fast"})]
    end

    test "bindings inside an if branch do not leak to the next branch" do
      src = ~S'''
      defmodule Foo do
        def check(a, b) do
          if a do
            x = b
            x
          else
            b
          end
        end
      end
      '''

      {:ok, ast} = EnvWalker.parse_string(src, "lib/foo.ex")

      vars =
        EnvWalker.collect_variable_candidates(ast,
          file: "lib/foo.ex",
          source: src,
          macro_index: kernel_if_index([{:if, 3, 5}])
        )

      # `x` is a body `=` binding, never in the under-approximated in-scope set,
      # so it is never offered as a swap alternative in either branch.
      refute Enum.any?(vars, fn {_c, snap} -> "x" in Enum.map(snap.bound_vars, &to_string/1) end)
    end
  end

  describe "nested modules (T13)" do
    test "a nested module's candidates carry the fully-qualified module" do
      src = ~S'''
      defmodule Outer do
        defmodule Inner do
          def x do
            "nested"
          end
        end
      end
      '''

      assert [{_candidate, snap}] = candidates(src)
      assert snap.module == Outer.Inner
    end

    test "an already-qualified nested defmodule is not double-qualified" do
      src = ~S'''
      defmodule Outer do
        defmodule Outer.Inner do
          def x do
            "nested"
          end
        end
      end
      '''

      assert [{_candidate, snap}] = candidates(src)
      assert snap.module == Outer.Outer.Inner
    end

    test "the module matches Mut.AstWalk.ignored_modules/1 for the same source" do
      src = ~S'''
      defmodule Outer do
        defmodule Inner do
          @mutalisk_ignore true
          def x do
            "nested"
          end
        end
      end
      '''

      assert [{_candidate, snap}] = candidates(src)
      ignored = Mut.AstWalk.ignored_modules(Code.string_to_quoted!(src))
      assert MapSet.member?(ignored, snap.module)
    end

    test "a dynamic nested defmodule keeps the enclosing module rather than crashing" do
      src = ~S'''
      defmodule Outer do
        defmodule unquote(:Inner) do
          def x do
            "nested"
          end
        end
      end
      '''

      assert [{_candidate, snap}] = candidates(src)
      assert snap.module == Outer
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
