defmodule Mut.Mutator.ClauseDelete do
  @moduledoc """
  M87 clause-deletion mutator — extends M81's structural framing to
  `case` / `cond` / `with` constructs. In each block-form construct, delete one
  clause; opt-in, fallback-routed (the candidate's whole-node span is
  re-rendered with the clause removed). Aggressive hazards up front, mirroring
  M81's discipline:

    * **`case` / `cond` last clause excluded** — it's the catch-all; deletion
      crashes on no-match.
    * **`cond` `true ->` clauses excluded** — the explicit fallback; deletion
      crashes the same way.
    * **`with` `<-` chain skipped** — orphan-binding-shaped (a deleted bind
      step's name would be read in `do`); only the `else` clauses are mutated.
    * **`with` single-`else`-clause skipped** — deletion would remove the only
      `else` (structurally invalid).
    * **M89 error-only clauses skipped** — clauses whose body is a single
      `raise`/`throw`/`exit` (or a block whose last statement is one) are
      the idiomatic "shouldn't-happen" arms. The test suite rarely exercises
      them, so deletion is observationally equivalent — the dominant
      equivalent class behind plug 26.8% in M88. Excluding them shaves the
      surface's noise without losing real kills.

  Hazards are filtered by the collector
  (`Mut.AstWalk.clause_delete_candidates`); the mutator simply rebuilds the
  construct without the indexed clause, in the section the collector identified.

  *Out of scope:* `receive` / `try` clause deletion (later); graduation flip
  (M88 decides).
  """
  @behaviour Mut.Mutator

  alias Mut.Mutation
  alias Mut.Oracle.AstCandidate
  alias Mut.Oracle.DispatchSite

  @kind :clause_delete

  @impl true
  def name, do: "ClauseDelete"

  @impl true
  def description, do: "Delete a clause from case / cond / with (else)."

  @impl true
  def targets, do: [:clause_delete]

  @impl true
  def applicable?(node, %Mut.Context{} = ctx) do
    ctx.engine == :fallback and construct_node?(node) and is_integer(clause_index(ctx)) and
      section(ctx) != nil
  end

  @impl true
  def mutate(node, %Mut.Context{} = ctx) do
    if applicable?(node, ctx) do
      build_mutation(node, section(ctx), clause_index(ctx))
    else
      []
    end
  end

  @impl true
  def equivalent?(_mutation), do: false

  @spec compatible?(AstCandidate.t(), DispatchSite.t() | nil) :: boolean
  def compatible?(%AstCandidate{syntactic_name: :clause_delete}, _site), do: true
  def compatible?(_candidate, _site), do: false

  defp construct_node?({kind, _meta, _args}) when kind in [:case, :cond, :with], do: true
  defp construct_node?(_node), do: false

  # The candidate's ast_path is
  # `[:clause_delete, file, line, col, section, index]`
  # (see `Mut.AstWalk.clause_delete_candidates`); the section and index sit at
  # known offsets from the tail.
  defp clause_index(%Mut.Context{ast_path: path}) when is_list(path) do
    case Enum.reverse(path) do
      [i, _section | _rest] when is_integer(i) -> i
      _ -> nil
    end
  end

  defp clause_index(_ctx), do: nil

  defp section(%Mut.Context{ast_path: path}) when is_list(path) do
    case Enum.reverse(path) do
      [_i, section | _rest] when section in [:case_do, :cond_do, :with_else] -> section
      _ -> nil
    end
  end

  defp section(_ctx), do: nil

  # case `do` clauses.
  defp build_mutation({:case, meta, [scrutinee, [{:do, clauses}]]} = node, :case_do, i)
       when length(clauses) > i do
    new_clauses = List.delete_at(clauses, i)
    mutation(node, {:case, meta, [scrutinee, [{:do, new_clauses}]]}, "case clause #{i}")
  end

  # cond `do` clauses.
  defp build_mutation({:cond, meta, [[{:do, clauses}]]} = node, :cond_do, i)
       when length(clauses) > i do
    new_clauses = List.delete_at(clauses, i)
    mutation(node, {:cond, meta, [[{:do, new_clauses}]]}, "cond clause #{i}")
  end

  # with `else` clauses (the trailing keyword-list's `:else` entry).
  defp build_mutation({:with, meta, args} = node, :with_else, i)
       when is_list(args) do
    last = List.last(args)
    leading = Enum.drop(args, -1)

    with true <- is_list(last) and Keyword.keyword?(last),
         else_clauses when is_list(else_clauses) <- Keyword.get(last, :else),
         true <- length(else_clauses) > i do
      new_else = List.delete_at(else_clauses, i)
      new_kw = Keyword.put(last, :else, new_else)
      mutation(node, {:with, meta, leading ++ [new_kw]}, "with else clause #{i}")
    else
      _ -> []
    end
  end

  defp build_mutation(_node, _section, _i), do: []

  defp mutation(original, mutated, label) do
    [
      %Mutation{
        original_ast: original,
        mutated_ast: mutated,
        description: "delete #{label}",
        mutation_kind: @kind,
        guard_safe?: true,
        metadata: %{change: label}
      }
    ]
  end
end
