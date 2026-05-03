defmodule Mut.Mutator.Boolean do
  @moduledoc "Mutates boolean operators."
  @behaviour Mut.Mutator

  alias Mut.Mutation
  alias Mut.Oracle.AstCandidate
  alias Mut.Oracle.DispatchSite

  @strict_names [:and, :or]
  @truthy_names [:&&, :||]
  @accepted_names @strict_names ++ @truthy_names
  @arity 2
  @kind :boolean_op
  @replacements %{
    :and => [:or],
    :or => [:and],
    :&& => [:||],
    :|| => [:&&]
  }
  @guard_safe %{:and => true, :or => true, :&& => false, :|| => false}

  @impl true
  def name, do: "Boolean"

  @impl true
  def description, do: "Replace boolean operators."

  @impl true
  def targets, do: [:dispatch]

  @impl true
  def applicable?(node, %Mut.Context{} = ctx) do
    ctx.env_context == nil and shape_matches?(node)
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
      module_accepted?(site.resolved_name, site.resolved_module)
  end

  defp module_accepted?(name, module) when name in @strict_names, do: module in [Kernel, :erlang]
  defp module_accepted?(name, Kernel) when name in @truthy_names, do: true
  defp module_accepted?(_name, _module), do: false

  defp shape_matches?({op, _meta, args}) when op in @accepted_names and length(args) == @arity,
    do: true

  defp shape_matches?(_node), do: false

  defp build_mutations({op, meta, args} = node) do
    for replacement <- Map.fetch!(@replacements, op) do
      %Mutation{
        original_ast: node,
        mutated_ast: {replacement, meta, args},
        description: "replace #{op} with #{replacement}",
        mutation_kind: @kind,
        guard_safe?: Map.fetch!(@guard_safe, replacement),
        metadata: %{operator: op, replacement: replacement}
      }
    end
  end
end
