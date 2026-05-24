defmodule Mut.Mutator.FloatLiteral do
  @moduledoc """
  M44 env-walker literal mutator. Replaces float body literals.

  Replacement table:

    * `0.0` → `1.0`
    * finite `f` (f != 0.0) → `0.0`
    * finite `f` (f != 0.0) → `f + 1.0`

  Eligibility mirrors `Mut.Mutator.StringLiteral` (M39 binding):
  the site is in `scope: :function_body`, `context: nil`,
  `trust_level: :trusted`, and the literal is a float. The walker
  (`Mut.EnvWalker.collect_literal_candidates/2`) enforces the
  context conditions before this mutator sees a candidate;
  `applicable?/2` checks defensively.

  Float source literals are always finite (`NaN` / infinity are not
  expressible as literals), so no special non-finite guard is needed.
  Fallback-routed and opt-in (`--enable env_walker`), per the v1.15
  no-stable-id-migration strategy.
  """

  @behaviour Mut.Mutator

  alias Mut.Mutation
  alias Mut.Oracle.AstCandidate
  alias Mut.Oracle.DispatchSite

  @impl true
  def name, do: "FloatLiteral"

  @impl true
  def description, do: "Replace float literal in function body."

  @impl true
  def targets, do: [:env_walker]

  @impl true
  def applicable?(node, %Mut.Context{} = ctx) do
    ctx.env_context == nil and ctx.engine in [:fallback, :schema] and float_literal?(node)
  end

  @impl true
  def mutate(node, %Mut.Context{} = ctx) do
    if applicable?(node, ctx), do: build_mutations(node), else: []
  end

  @impl true
  def equivalent?(%Mutation{metadata: %{from: from, to: to}}), do: from == to
  def equivalent?(_mutation), do: false

  @spec compatible?(AstCandidate.t(), DispatchSite.t() | nil) :: boolean
  def compatible?(%AstCandidate{} = candidate, _site) do
    float_literal?(candidate.node)
  end

  defp float_literal?({:__block__, _meta, [value]}) when is_float(value), do: true
  defp float_literal?(_), do: false

  defp build_mutations({:__block__, meta, [value]} = node) do
    value
    |> replacements()
    |> Enum.map(fn replacement ->
      %Mutation{
        original_ast: node,
        mutated_ast: {:__block__, meta, [replacement]},
        description: "replace float literal #{value} with #{replacement}",
        mutation_kind: :float_literal,
        guard_safe?: false,
        metadata: %{from: value, to: replacement}
      }
    end)
  end

  defp replacements(+0.0), do: [1.0]
  defp replacements(value) when is_float(value), do: [0.0, value + 1.0]
end
