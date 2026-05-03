defmodule Mut.Mutator.GuardTypeTest do
  @moduledoc "Mutates guard type-test predicates."
  @behaviour Mut.Mutator

  alias Mut.Mutation
  alias Mut.Oracle.AstCandidate
  alias Mut.Oracle.DispatchSite

  @accepted_modules [Kernel, :erlang]
  @accepted_names ~w(
    is_atom is_binary is_boolean is_float is_integer is_list is_map is_nil
    is_number is_pid is_port is_reference is_tuple
  )a
  @arity 1
  @kind :guard_type_test
  @replacements %{
    is_integer: [:is_float, :is_number],
    is_float: [:is_integer, :is_number],
    is_number: [:is_integer, :is_float],
    is_atom: [:is_nil],
    is_nil: [:is_atom],
    is_list: [:is_tuple],
    is_tuple: [:is_list],
    is_map: [:is_list],
    is_binary: [],
    is_boolean: [],
    is_pid: [],
    is_port: [],
    is_reference: []
  }

  @impl true
  def name, do: "GuardTypeTest"

  @impl true
  def description, do: "Replace guard type-test predicates."

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

  defp shape_matches?({name, _meta, args})
       when name in @accepted_names and length(args) == @arity,
       do: true

  # is_function/2 has a distinct signature; v1 avoids arity-changing guard mutations.
  defp shape_matches?(_node), do: false

  defp build_mutations({name, meta, args} = node) do
    for replacement <- Map.fetch!(@replacements, name) do
      %Mutation{
        original_ast: node,
        mutated_ast: {replacement, meta, args},
        description: "replace guard #{name} with #{replacement}",
        mutation_kind: @kind,
        guard_safe?: true,
        metadata: %{operator: name, replacement: replacement}
      }
    end
  end
end
