defmodule Mut.Mutator.ClauseDeleteTest do
  use ExUnit.Case, async: true

  @moduledoc "M87 ClauseDelete + AstWalk.clause_delete_candidates (case / cond / with)."

  alias Mut.AstWalk
  alias Mut.Context
  alias Mut.Mutator.ClauseDelete

  defp candidates(src) do
    ast = Code.string_to_quoted!(src, columns: true, token_metadata: true)
    AstWalk.clause_delete_candidates(ast, file: "m.ex", source: src)
  end

  defp ctx(ast_path),
    do: %Context{engine: :fallback, file: "m.ex", ast_path: ast_path, ast_path_hash: "h"}

  describe "metadata" do
    test "name/targets" do
      assert ClauseDelete.name() == "ClauseDelete"
      assert ClauseDelete.targets() == [:clause_delete]
    end
  end

  describe "case clauses" do
    @case_src """
    defmodule M do
      def f(x) do
        case x do
          1 -> :one
          2 -> :two
          _ -> :other
        end
      end
    end
    """

    test "emits one candidate per non-last case clause; last excluded" do
      cands = candidates(@case_src)
      assert length(cands) == 2

      sections =
        Enum.map(cands, fn c -> Enum.take(Enum.reverse(c.ast_path), 2) end)

      # [index, section] reversed (from tail).
      assert Enum.all?(sections, fn [_i, section] -> section == :case_do end)
      assert Enum.sort(Enum.map(sections, fn [i, _s] -> i end)) == [0, 1]
    end

    test "deletes the indexed case clause, preserves the rest" do
      [c0, _c1] = candidates(@case_src)
      [m] = ClauseDelete.mutate(c0.node, ctx(c0.ast_path))
      assert {:case, _, [_scrut, [{:do, clauses}]]} = m.mutated_ast
      assert length(clauses) == 2

      # Index 0 (the `1 -> :one`) removed; index 0 of the new list is the old index 1 (the `2 -> :two`).
      [{:->, _, [[2], :two]}, {:->, _, _}] = clauses
    end
  end

  describe "cond clauses" do
    @cond_src """
    defmodule M do
      def f(x) do
        cond do
          x > 10 -> :big
          x > 0 -> :pos
          true -> :nonpos
        end
      end
    end
    """

    test "skips the last clause AND the `true ->` fallback (here both happen to be the same)" do
      cands = candidates(@cond_src)
      # last clause is `true -> :nonpos` (excluded as last AND as cond_true_clause);
      # remaining non-last clauses: index 0 (`x > 10`) and index 1 (`x > 0`).
      # Neither is a `true ->` clause, so both deletable.
      assert length(cands) == 2

      assert Enum.all?(cands, fn c ->
               [_i, section | _] = Enum.reverse(c.ast_path)
               section == :cond_do
             end)
    end

    test "skips a `true ->` clause that appears earlier than last" do
      src = """
      defmodule M do
        def f(x) do
          cond do
            x > 10 -> :big
            true -> :fallback_early
            x > 0 -> :pos
          end
        end
      end
      """

      cands = candidates(src)
      # 3 clauses; last excluded; the middle is `true -> ...` (excluded by hazard);
      # only `x > 10 -> :big` (index 0) is deletable.
      assert length(cands) == 1
      [_i, _section] = Enum.reverse(hd(cands).ast_path) |> Enum.take(2)
    end
  end

  describe "with `else` clauses" do
    @with_src """
    defmodule M do
      def f(x) do
        with {:ok, a} <- find(x),
             {:ok, b} <- check(a) do
          {a, b}
        else
          {:error, :not_found} -> :nf
          {:error, _other} -> :err
        end
      end
    end
    """

    test "emits one candidate per else clause (2 here)" do
      cands = candidates(@with_src)
      assert length(cands) == 2

      assert Enum.all?(cands, fn c ->
               [_i, section | _] = Enum.reverse(c.ast_path)
               section == :with_else
             end)
    end

    test "skips with that has only one else clause" do
      src = """
      defmodule M do
        def f(x) do
          with {:ok, v} <- find(x) do
            v
          else
            _ -> :err
          end
        end
      end
      """

      assert candidates(src) == []
    end

    test "deletes the indexed else clause" do
      [c0, _c1] = candidates(@with_src)
      [m] = ClauseDelete.mutate(c0.node, ctx(c0.ast_path))
      assert {:with, _, args} = m.mutated_ast
      kw = List.last(args)
      assert is_list(Keyword.get(kw, :else))
      assert length(Keyword.get(kw, :else)) == 1
    end
  end

  describe "applicability" do
    test "not applicable in schema engine or on non-construct nodes" do
      [c, _other] = candidates(@case_src)
      schema_ctx = %{ctx(c.ast_path) | engine: :schema}
      refute ClauseDelete.applicable?(c.node, schema_ctx)
      refute ClauseDelete.applicable?({:+, [], [1, 2]}, ctx([0]))
    end
  end

  describe "M89 error-only clause hazard" do
    test "skips a case clause whose body is just `raise`" do
      src = """
      defmodule M do
        def f(x) do
          case x do
            :ok -> handle()
            :err -> raise "bad"
            _ -> :fallback
          end
        end
      end
      """

      # 3 clauses; last excluded (the `_ -> :fallback`); the `raise`-only
      # arm at index 1 is the M89 hazard. Only index 0 (`:ok -> handle()`)
      # remains deletable.
      cands = candidates(src)
      assert length(cands) == 1
      [idx, section | _] = Enum.reverse(hd(cands).ast_path)
      assert section == :case_do and idx == 0
    end

    test "skips a with-else clause whose body is just `throw`" do
      src = """
      defmodule M do
        def f(x) do
          with {:ok, v} <- find(x),
               {:ok, w} <- check(v) do
            {v, w}
          else
            {:error, :not_found} -> throw(:not_found)
            other -> {:err, other}
          end
        end
      end
      """

      # 2 else-clauses; index 0 is `throw(...)`-only (skipped); index 1 stays.
      cands = candidates(src)
      assert length(cands) == 1
      [idx, section | _] = Enum.reverse(hd(cands).ast_path)
      assert section == :with_else and idx == 1
    end

    test "non-error clauses with a block body still emitted" do
      src = """
      defmodule M do
        def f(x) do
          case x do
            :ok ->
              log_it()
              :handled
            _ -> :other
          end
        end
      end
      """

      # 2 clauses; last excluded; index 0 body is a block ending in `:handled`
      # — NOT a raise/throw/exit, so NOT skipped.
      cands = candidates(src)
      assert length(cands) == 1
    end
  end
end
