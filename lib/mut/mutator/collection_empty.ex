defmodule Mut.Mutator.CollectionEmpty do
  @moduledoc """
  M45 env-walker literal mutator. Empties non-empty collection literals
  in function-body context.

  Replacement table:

    * non-empty list `[...]` → `[]`
    * 2-tuple `{a, b}` → `{}`

  Scope (M45): only the collection shapes that the parser's
  `literal_encoder` wraps in `{:__block__, meta, [value]}` — genuine
  `[...]` list literals and `{a, b}` 2-tuple literals. The encoder leaves
  structural lists (call-arg keyword lists, `do:` blocks) **unwrapped**,
  so they never reach this mutator — that is what makes list detection
  safe without false positives on options/blocks.

  Maps (`%{...}`) and n-tuples (`{a, b, c}`) are unwrapped AST nodes
  (`{:%{}, ...}` / `{:{}, ...}`) and are **deferred to v1.16**: detecting
  them needs a separate walk pass plus struct-map exclusion, which is
  cleaner to build alongside the EnvWalker consolidation (M43, also
  v1.16). See `docs/decisions/M43_envwalker_consolidation.md`.

  Body-position only: the candidate's `env_context` must be `nil`, so
  list/tuple patterns in match and guard positions are never reached.
  Fallback-routed and opt-in (`--enable env_walker`).
  """

  @behaviour Mut.Mutator

  alias Mut.Mutation
  alias Mut.Oracle.AstCandidate
  alias Mut.Oracle.DispatchSite

  @impl true
  def name, do: "CollectionEmpty"

  @impl true
  def description, do: "Empty a non-empty collection literal in function body."

  @impl true
  def targets, do: [:env_walker]

  @impl true
  def applicable?(node, %Mut.Context{} = ctx) do
    ctx.env_context == nil and ctx.engine == :fallback and non_empty_collection?(node)
  end

  @impl true
  def mutate(node, %Mut.Context{} = ctx) do
    if applicable?(node, ctx), do: build_mutations(node), else: []
  end

  @impl true
  def equivalent?(_mutation), do: false

  @spec compatible?(AstCandidate.t(), DispatchSite.t() | nil) :: boolean
  def compatible?(%AstCandidate{} = candidate, _site) do
    non_empty_collection?(candidate.node)
  end

  defp non_empty_collection?({:__block__, _meta, [value]}) when is_list(value), do: value != []

  defp non_empty_collection?({:__block__, _meta, [value]})
       when is_tuple(value) and tuple_size(value) == 2,
       do: true

  defp non_empty_collection?(_), do: false

  defp build_mutations({:__block__, meta, [value]} = node) when is_list(value) do
    [empty_mutation(node, meta, [], :list)]
  end

  defp build_mutations({:__block__, meta, [_value]} = node) do
    [empty_mutation(node, meta, {}, :tuple)]
  end

  defp empty_mutation(node, meta, empty, kind) do
    %Mutation{
      original_ast: node,
      mutated_ast: {:__block__, meta, [empty]},
      description: "empty #{kind} literal",
      mutation_kind: :collection_empty,
      guard_safe?: false,
      metadata: %{collection: kind}
    }
  end
end
