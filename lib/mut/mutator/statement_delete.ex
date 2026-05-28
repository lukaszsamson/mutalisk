defmodule Mut.Mutator.StatementDelete do
  @moduledoc """
  M81 statement-deletion mutator. In a multi-statement `def`/`defp` body
  (`{:__block__, _, stmts}`), delete one non-last statement. The deferred
  high-yield classic from PIT/Stryker, intrinsically the catalogue's noisiest
  surface — opt-in with **aggressive hazard gating up front**.

  Hazard gates (in `Mut.AstWalk.statement_delete_candidates`):

    * **Body position only.** The walk visits the file's `defmodule` → `def` /
      `defp` directly, so candidates are only emitted from function bodies —
      patterns, guards, and `case`/`with` scrutinee blocks are never reached.
    * **Last statement excluded.** A function's last statement is its return
      value; deletion is the noisiest sub-class per the M39 sketch and is
      opt-in-within-opt-in territory — excluded here by default.
    * **Orphan-binding hazard.** If the deleted statement binds a name (via
      `=`) that any later statement reads, the body would no longer compile
      (undefined variable). Skip.

  Fallback-routed: the candidate's `source_span` is the whole `def` node
  (block-form, `:end` metadata); the mutation re-emits the def with the
  statement removed and `Mut.FallbackPatch` re-renders the def's source
  (`Macro.to_string` round-trips body semantics; formatting changes in the
  re-render are irrelevant for mutation behaviour). Opt-in.

  *Out of scope:* `case`-clause deletion, last-statement deletion (both noisier
  surfaces deferred).
  """
  @behaviour Mut.Mutator

  alias Mut.Mutation
  alias Mut.Oracle.AstCandidate
  alias Mut.Oracle.DispatchSite

  @kind :statement_delete

  @impl true
  def name, do: "StatementDelete"

  @impl true
  def description, do: "Delete a non-last statement from a function body."

  @impl true
  def targets, do: [:statement_delete]

  @impl true
  def applicable?(node, %Mut.Context{} = ctx) do
    ctx.engine == :fallback and def_node?(node) and is_integer(stmt_index(ctx))
  end

  @impl true
  def mutate(node, %Mut.Context{} = ctx) do
    if applicable?(node, ctx), do: build_mutations(node, stmt_index(ctx)), else: []
  end

  @impl true
  def equivalent?(_mutation), do: false

  @spec compatible?(AstCandidate.t(), DispatchSite.t() | nil) :: boolean
  def compatible?(%AstCandidate{syntactic_name: :statement_delete}, _site), do: true
  def compatible?(_candidate, _site), do: false

  defp def_node?({name, _meta, [_head, body_kw]})
       when name in [:def, :defp] and is_list(body_kw),
       do: Keyword.has_key?(body_kw, :do)

  defp def_node?(_node), do: false

  # The candidate's ast_path is `[:statement_delete, file, line, col, index]`
  # (see Mut.AstWalk.statement_delete_candidates); the index is the last
  # element. Anything else => not our candidate.
  defp stmt_index(%Mut.Context{ast_path: path}) when is_list(path) do
    case List.last(path) do
      i when is_integer(i) -> i
      _ -> nil
    end
  end

  defp stmt_index(_ctx), do: nil

  defp build_mutations({name, meta, [head, body_kw]} = node, index) do
    case Keyword.fetch!(body_kw, :do) do
      {:__block__, block_meta, stmts} when length(stmts) > index ->
        new_stmts = List.delete_at(stmts, index)

        new_body =
          case new_stmts do
            [single] -> single
            many -> {:__block__, block_meta, many}
          end

        new_kw = Keyword.put(body_kw, :do, new_body)

        [
          %Mutation{
            original_ast: node,
            mutated_ast: {name, meta, [head, new_kw]},
            description: "delete statement #{index} from #{name}",
            mutation_kind: @kind,
            guard_safe?: true,
            metadata: %{kind: name, index: index}
          }
        ]

      _ ->
        []
    end
  end
end
