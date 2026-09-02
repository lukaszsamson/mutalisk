defmodule Mut.AstWalkCodegenRefusalTest do
  use ExUnit.Case, async: true

  @moduledoc """
  T14 (BUGS.txt 19): every candidate collector applies the SAME
  code-generation refusal policy — `quote`/`unquote` subtrees are pruned and
  `defmacro`/`defmacrop` bodies are skipped — so no walker mutates
  expansion-time code. Each fixture below places the construct the walker
  looks for in three positions: inside a `quote do … end`, inside a
  `defmacro` body, and in an ordinary runtime function. Only the last one
  may yield candidates.

  Also covers T15 (statement-delete must never delete an `alias`/`import`/
  `require`/`use` lexical directive) and T17 (a literal pipe head must not
  suppress pipeline-drop candidates).
  """

  describe "T14: pin_candidates/2 refuses quote and defmacro bodies" do
    @pin_fixture """
    defmodule Fx do
      defmacro gen(value) do
        quote do
          case unquote(value) do
            ^outer -> :quoted
            _ -> :other
          end
        end
      end

      defmacrop raw(a, b) do
        case b do
          ^a -> :in_macro
          _ -> :other
        end
      end

      def plain(a, b) do
        case b do
          ^a -> :outside
          _ -> :other
        end
      end
    end
    """

    test "only the runtime function's pin is a candidate" do
      candidates = pins(@pin_fixture)

      assert [%{syntactic_name: :^, line: 20}] = candidates
    end

    test "the same pin outside any codegen context is still collected" do
      assert [%{line: 3}] = pins("def plain(a, b) do\n  case b do\n    ^a -> 1\n  end\nend\n")
    end
  end

  describe "T14: conditional_candidates/2 refuses quote and defmacro bodies" do
    @conditional_fixture """
    defmodule Fx do
      defmacro gen(value) do
        quote do
          if unquote(value) do
            :quoted
          end
        end
      end

      defmacrop raw(value) do
        if value do
          :in_macro
        end
      end

      def plain(value) do
        if value do
          :outside
        end
      end
    end
    """

    test "only the runtime function's if is a candidate" do
      assert [%{syntactic_name: :if, line: 17}] = conditionals(@conditional_fixture)
    end
  end

  describe "T14: statement_delete_candidates/2 refuses quote and defmacro bodies" do
    @statement_delete_fixture """
    defmodule Fx do
      defmacro gen(name) do
        quote do
          def unquote(name)(x) do
            log(x)
            notify(x)
            x
          end
        end
      end

      defmacrop raw do
        def generated(x) do
          log(x)
          notify(x)
          x
        end
      end

      def plain(x) do
        log(x)
        notify(x)
        x
      end
    end
    """

    test "only the runtime function yields statement-delete candidates" do
      candidates = statement_deletes(@statement_delete_fixture)

      assert Enum.all?(candidates, &(&1.line == 20)),
             "expected only the `def plain` at line 20, got #{inspect(Enum.map(candidates, & &1.line))}"

      assert candidates != []
    end
  end

  describe "T14: clause_delete_candidates/2 refuses quote and defmacro bodies" do
    @clause_delete_fixture """
    defmodule Fx do
      defmacro gen(value) do
        quote do
          case unquote(value) do
            1 -> :one
            2 -> :two
            _ -> :other
          end
        end
      end

      defmacrop raw(value) do
        case value do
          1 -> :one
          2 -> :two
          _ -> :other
        end
      end

      def plain(value) do
        case value do
          1 -> :one
          2 -> :two
          _ -> :other
        end
      end
    end
    """

    test "only the runtime function's case yields clause-delete candidates" do
      candidates = clause_deletes(@clause_delete_fixture)

      assert Enum.all?(candidates, &(&1.line == 21)),
             "expected only the `case` at line 21, got #{inspect(Enum.map(candidates, & &1.line))}"

      assert candidates != []
    end
  end

  describe "T14: pipeline_drop_candidates/2 refuses quote and defmacro bodies" do
    @pipeline_fixture """
    defmodule Fx do
      defmacro gen(value) do
        quote do
          unquote(value) |> one() |> two() |> three()
        end
      end

      defmacrop raw(value) do
        value |> one() |> two() |> three()
      end

      def plain(value) do
        value |> one() |> two() |> three()
      end
    end
    """

    test "only the runtime function's chain yields pipeline-drop candidates" do
      candidates = pipelines(@pipeline_fixture)

      assert [%{syntactic_name: :pipeline_drop_stage, line: 13}] = candidates
    end
  end

  describe "T14: map_update_drop_candidates/2 refuses quote and defmacro bodies" do
    @map_update_fixture """
    defmodule Fx do
      defmacro gen(value) do
        quote do
          %{unquote(value) | a: 1}
        end
      end

      defmacrop raw(value) do
        %{value | a: 1}
      end

      def plain(value) do
        %{value | a: 1}
      end
    end
    """

    test "only the runtime function's map update is a candidate" do
      assert [%{syntactic_name: :map_update_drop, line: 13}] = map_updates(@map_update_fixture)
    end
  end

  describe "T14: receive_timeout_candidates/2 refuses quote and defmacro bodies" do
    @receive_fixture """
    defmodule Fx do
      defmacro gen do
        quote do
          receive do
            msg -> msg
          after
            100 -> :timeout
          end
        end
      end

      defmacrop raw do
        receive do
          msg -> msg
        after
          100 -> :timeout
        end
      end

      def plain do
        receive do
          msg -> msg
        after
          100 -> :timeout
        end
      end
    end
    """

    test "only the runtime function's receive is a candidate" do
      assert [%{syntactic_name: :receive_timeout, line: 21}] = receive_timeouts(@receive_fixture)
    end
  end

  describe "T15: statement-delete never deletes a lexical-scope directive" do
    test "alias / import / require / use statements are hazards" do
      source = """
      defmodule Fx do
        def plain(x) do
          alias Very.Deep.Helper
          import List, only: [first: 1]
          require Logger
          use SomeBehaviour
          value = Helper.run(x)
          Logger.debug(first([value]))
          value
        end
      end
      """

      # Statement indexes: 0 alias, 1 import, 2 require, 3 use, 4 `value = …`
      # (orphan-binding hazard: read later), 5 `Logger.debug(…)`, 6 last (excluded).
      # Only index 5 survives every hazard gate.
      assert [%{ast_path: [:statement_delete, "sample.ex", 2, 3, 5]}] = statement_deletes(source)
    end

    test "the directive gate does not affect ordinary statements" do
      source = """
      defmodule Fx do
        def plain(x) do
          log(x)
          notify(x)
          x
        end
      end
      """

      indexes = for c <- statement_deletes(source), do: List.last(c.ast_path)
      assert indexes == [0, 1]
    end

    test "a local call named like a directive but shaped as a variable is untouched" do
      # `use` here is a variable read, not a directive call; the hazard gate must
      # not swallow the surrounding statements.
      source = """
      defmodule Fx do
        def plain(use) do
          log(use)
          notify(use)
          use
        end
      end
      """

      indexes = for c <- statement_deletes(source), do: List.last(c.ast_path)
      assert indexes == [0, 1]
    end
  end

  describe "T17: literal-headed pipelines yield pipeline-drop candidates" do
    test "a list head is not dropped on the floor" do
      source = "def a(f), do: [1, 2, 3] |> Enum.map(f) |> Enum.filter(f) |> Enum.take(2)\n"
      [candidate] = pipelines(source)

      assert candidate.line == 1
      assert candidate.column == 15

      assert slice(source, candidate) ==
               "[1, 2, 3] |> Enum.map(f) |> Enum.filter(f) |> Enum.take(2)"
    end

    test "an integer head is not dropped on the floor" do
      source = "def d(f), do: 5 |> foo() |> bar() |> baz()\n"
      [candidate] = pipelines(source)

      assert candidate.column == 15
      assert slice(source, candidate) == "5 |> foo() |> bar() |> baz()"
    end

    test "a two-element tuple head is not dropped on the floor" do
      source = "def c(a, b), do: {a, b} |> Tuple.to_list() |> Enum.map(&f/1) |> Enum.take(2)\n"
      [candidate] = pipelines(source)

      assert candidate.column == 18

      assert slice(source, candidate) ==
               "{a, b} |> Tuple.to_list() |> Enum.map(&f/1) |> Enum.take(2)"
    end

    test "a variable head keeps its exact previous span" do
      source = "def b(f, x), do: x |> Enum.map(f) |> Enum.filter(f) |> Enum.take(2)\n"
      [candidate] = pipelines(source)

      assert candidate.column == 18
      assert slice(source, candidate) == "x |> Enum.map(f) |> Enum.filter(f) |> Enum.take(2)"
    end

    test "literal and variable heads produce the same number of candidates" do
      literal = "def a(f), do: [1, 2] |> one(f) |> two(f) |> three(f) |> four(f)\n"
      variable = "def a(f, x), do: x |> one(f) |> two(f) |> three(f) |> four(f)\n"

      assert length(pipelines(literal)) == length(pipelines(variable))
    end
  end

  defp slice(source, candidate) do
    span = candidate.source_span
    binary_part(source, span.start_byte, span.end_byte - span.start_byte)
  end

  defp walk(source, fun) do
    assert {:ok, ast} = Mut.SourceParse.parse_string(source, "sample.ex")
    fun.(ast, file: "sample.ex", source: source)
  end

  defp pins(source), do: walk(source, &Mut.AstWalk.pin_candidates/2)
  defp conditionals(source), do: walk(source, &Mut.AstWalk.conditional_candidates/2)
  defp statement_deletes(source), do: walk(source, &Mut.AstWalk.statement_delete_candidates/2)
  defp clause_deletes(source), do: walk(source, &Mut.AstWalk.clause_delete_candidates/2)
  defp pipelines(source), do: walk(source, &Mut.AstWalk.pipeline_drop_candidates/2)
  defp map_updates(source), do: walk(source, &Mut.AstWalk.map_update_drop_candidates/2)
  defp receive_timeouts(source), do: walk(source, &Mut.AstWalk.receive_timeout_candidates/2)
end
