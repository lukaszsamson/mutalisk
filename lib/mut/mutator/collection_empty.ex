defmodule Mut.Mutator.CollectionEmpty do
  @moduledoc """
  Env-walker literal mutator. Empties non-empty collection literals in
  function-body context.

  Replacement table:

    * non-empty list `[...]` → `[]`            (M45)
    * 2-tuple `{a, b}` → `{}`                  (M45)
    * non-empty map `%{...}` → `%{}`           (M50)
    * n-tuple `{a, b, c}` → `{}` (arity >= 3)  (M50)

  Detection:

    * Lists and 2-tuples are wrapped by the parser's `literal_encoder` in
      `{:__block__, meta, [value]}`. The encoder leaves structural lists
      (call-arg keyword lists, `do:` blocks) **unwrapped**, so they never
      reach this mutator — no false positives on options/blocks.
    * Maps and n-tuples are unwrapped AST nodes (`{:%{}, …}` / `{:{}, …}`),
      detected by a dedicated `Mut.EnvWalker` pass (M50). Excluded:
      struct maps `%S{...}` (never emptied — would break required keys),
      map-update `%{m | …}` forms, and 2-tuples (`{:{}}` covers arity 0/1
      and ≥3; the wrapped path owns arity 2).

  Body-position only: the candidate's `env_context` must be `nil`, so
  collection patterns in match and guard positions are never reached.
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

  # M50: bare map (non-empty, not a `%{m | …}` update) and n-tuple
  # (arity >= 3). Both are unwrapped AST nodes.
  defp non_empty_collection?({:%{}, _meta, pairs}) when is_list(pairs),
    do: pairs != [] and not map_update?(pairs)

  defp non_empty_collection?({:{}, _meta, elems}) when is_list(elems), do: length(elems) >= 3

  defp non_empty_collection?(_), do: false

  defp map_update?([{:|, _meta, _args} | _rest]), do: true
  defp map_update?(_pairs), do: false

  defp build_mutations({:__block__, meta, [value]} = node) when is_list(value),
    do: [empty_mutation(node, {:__block__, meta, [[]]}, "empty list literal", :list)]

  defp build_mutations({:__block__, meta, [_value]} = node),
    do: [empty_mutation(node, {:__block__, meta, [{}]}, "empty tuple literal", :tuple)]

  defp build_mutations({:%{}, meta, _pairs} = node),
    do: [empty_mutation(node, {:%{}, meta, []}, "empty map literal", :map)]

  defp build_mutations({:{}, meta, _elems} = node),
    do: [empty_mutation(node, {:{}, meta, []}, "empty tuple literal", :tuple)]

  defp empty_mutation(node, mutated_ast, description, kind) do
    %Mutation{
      original_ast: node,
      mutated_ast: mutated_ast,
      description: description,
      mutation_kind: :collection_empty,
      guard_safe?: false,
      metadata: %{collection: kind}
    }
  end
end
