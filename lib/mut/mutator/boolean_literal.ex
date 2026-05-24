defmodule Mut.Mutator.BooleanLiteral do
  @moduledoc """
  M23: Replace boolean literals in function-body context.

  Replacement table:

    * `true` → `false`
    * `false` → `true`

  Routes through the fallback engine; see `Mut.Mutator.IntegerLiteral`
  for the rationale.
  """
  @behaviour Mut.Mutator

  alias Mut.Mutation
  alias Mut.Oracle.AstCandidate
  alias Mut.Oracle.DispatchSite

  @impl true
  def name, do: "BooleanLiteral"

  @impl true
  def description, do: "Replace boolean literal in function body."

  @impl true
  def targets, do: [:body_literal, :pattern_literal]

  @impl true
  def applicable?(node, %Mut.Context{} = ctx) do
    ctx.env_context in [nil, :match] and ctx.engine in [:fallback, :schema] and
      boolean_literal?(node)
  end

  @impl true
  def mutate(node, %Mut.Context{} = ctx) do
    if applicable?(node, ctx), do: build_mutations(node), else: []
  end

  @impl true
  def equivalent?(_mutation), do: false

  @spec compatible?(AstCandidate.t(), DispatchSite.t() | nil) :: boolean
  def compatible?(%AstCandidate{} = candidate, _site) do
    boolean_literal?(candidate.node)
  end

  defp boolean_literal?({:__block__, _meta, [value]}) when is_boolean(value), do: true
  defp boolean_literal?(_), do: false

  defp build_mutations({:__block__, _meta, [value]} = node) do
    replacement = not value

    [
      %Mutation{
        original_ast: node,
        # Strip parser meta (especially `:token`); render the bare
        # literal as plain source text via Macro.to_string.
        mutated_ast: replacement,
        description: "replace boolean literal #{value} with #{replacement}",
        mutation_kind: :boolean_literal_flip,
        guard_safe?: false,
        metadata: %{original_value: value, replacement_value: replacement}
      }
    ]
  end
end
