defmodule Mut.Mutator.MapUpdateDrop do
  @moduledoc """
  M94 niche mutator — drop a map-update, returning the unupdated map.
  In `%{m | k: v, a: 1}`, dropping the update yields just `m`. The
  mutation is observable on any test that depends on the updated key:
  the assertion `result[:k] == v` becomes false (the original `m[:k]`
  is whatever it was before).

  Structurally narrow surface — only `%{base | updates}` syntax with
  at least one update — but each candidate is a clean signal: tests
  that exercise the updated keys kill the mutant; tests that don't
  call out the change leave it surviving (the "is this update
  exercised?" signal we want from mutation testing).

  Hazard discipline:

    * Only triggers on `%{m | …}` (map-update syntax). Plain literals
      `%{a: 1, b: 2}` are not mutated here — they don't have the
      "preserve base / drop update" shape.
    * Plan note: "hazard-skip when result is not bound/returned"
      would catch the trivially-equivalent class where the
      `%{m | …}` expression is the last statement of a sequence
      whose value is discarded. We do **not** gate on that
      statically — the parent context isn't always visible (e.g.
      pipelines, function args), and the M62 gate quantifies the
      resulting equivalent rate. M95 measures; v1.27+ refines if
      noise warrants.

  Fallback-routed: the candidate's `source_span` is the whole `%{}`
  literal (its `:closing` meta yields the end position); the mutation
  emits the base map directly. Opt-in via `:map_update_drop`.

  *Out of scope:* mutating individual updated keys/values; per-key
  drops (drop one key from the update list while keeping others);
  map-key mutations on `%{a: 1, b: 2}` (separate sub-shape).
  """
  @behaviour Mut.Mutator

  alias Mut.Mutation
  alias Mut.Oracle.AstCandidate
  alias Mut.Oracle.DispatchSite

  @kind :map_update_drop

  @impl true
  def name, do: "MapUpdateDrop"

  @impl true
  def description, do: "Drop a map-update, returning the unupdated base."

  @impl true
  def targets, do: [:map_update_drop]

  @impl true
  def applicable?(node, %Mut.Context{} = ctx) do
    ctx.engine == :fallback and map_update?(node)
  end

  @impl true
  def mutate(node, %Mut.Context{} = ctx) do
    if applicable?(node, ctx), do: build_mutation(node), else: []
  end

  @impl true
  def equivalent?(_mutation), do: false

  @spec compatible?(AstCandidate.t(), DispatchSite.t() | nil) :: boolean
  def compatible?(%AstCandidate{syntactic_name: :map_update_drop}, _site), do: true
  def compatible?(_candidate, _site), do: false

  defp map_update?({:%{}, _meta, [{:|, _, [_base, updates]}]}) when is_list(updates), do: true
  defp map_update?(_node), do: false

  defp build_mutation({:%{}, _meta, [{:|, _, [base, _updates]}]} = node) do
    [
      %Mutation{
        original_ast: node,
        mutated_ast: base,
        description: "drop map update (return base)",
        mutation_kind: @kind,
        guard_safe?: true,
        metadata: %{}
      }
    ]
  end
end
