defmodule Mut.Mutator.GuardComparisonBoundary do
  @moduledoc "Mutates guard comparison boundary operators."
  @behaviour Mut.Mutator

  alias Mut.Mutation
  alias Mut.Oracle.AstCandidate
  alias Mut.Oracle.DispatchSite

  @accepted_modules [Kernel, :erlang]
  @accepted_names ~w(< <= > >=)a
  @arity 2
  @kind :guard_comparison_boundary
  @replacements %{
    :< => [:<=],
    :<= => [:<],
    :> => [:>=],
    :>= => [:>]
  }

  @impl true
  def name, do: "GuardComparisonBoundary"

  @impl true
  def description, do: "Replace guard comparison boundary operators."

  @impl true
  def targets, do: [:guard]

  @impl true
  def applicable?(node, %Mut.Context{} = ctx) do
    ctx.env_context == :guard and ctx.engine == :fallback and shape_matches?(node)
  end

  @impl true
  def mutate(node, %Mut.Context{} = ctx) do
    if applicable?(node, ctx), do: build_mutations(node), else: []
  end

  @impl true
  def equivalent?(_mutation), do: false

  @spec compatible?(AstCandidate.t(), DispatchSite.t()) :: boolean
  def compatible?(%AstCandidate{} = candidate, %DispatchSite{} = site) do
    candidate.syntactic_name == site.resolved_name and
      candidate.syntactic_arity == site.resolved_arity and
      site.resolved_module in @accepted_modules and
      site.resolved_name in @accepted_names
  end

  defp shape_matches?({op, _meta, args}) when op in @accepted_names and length(args) == @arity,
    do: true

  defp shape_matches?(_node), do: false

  defp build_mutations({op, meta, args} = node) do
    for replacement <- Map.fetch!(@replacements, op) do
      %Mutation{
        original_ast: node,
        mutated_ast: {replacement, meta, args},
        description: "replace guard #{op} with #{replacement}",
        mutation_kind: @kind,
        guard_safe?: true,
        metadata: %{operator: op, replacement: replacement}
      }
    end
  end
end
