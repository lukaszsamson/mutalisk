defmodule Mut.Mutator.BitwiseOperator do
  @moduledoc """
  M69 operator-expansion mutator. Swaps bitwise operations:

    * `band` ↔ `bor` ↔ `bxor` (bitwise logical)
    * `bsl` ↔ `bsr` (bit shifts)

  Matches the `Bitwise` (imported) / `:erlang` function-name forms
  (`band(a, b)` etc.). Opt-in, schema-routed (dispatch), mirroring
  `Mut.Mutator.Arithmetic`.
  """
  @behaviour Mut.Mutator

  alias Mut.Mutation
  alias Mut.Oracle.AstCandidate
  alias Mut.Oracle.DispatchSite

  @accepted_modules [Bitwise, :erlang]
  @accepted_names ~w(band bor bxor bsl bsr)a
  @arity 2
  @kind :bitwise_op
  @replacements %{
    band: [:bor, :bxor],
    bor: [:band, :bxor],
    bxor: [:band, :bor],
    bsl: [:bsr],
    bsr: [:bsl]
  }

  @impl true
  def name, do: "BitwiseOperator"

  @impl true
  def description, do: "Swap bitwise operators (band/bor/bxor, bsl/bsr)."

  @impl true
  def targets, do: [:dispatch]

  @impl true
  def applicable?(node, %Mut.Context{} = ctx) do
    ctx.env_context == nil and shape_matches?(node) and oracle_compatible?(node, ctx)
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

  defp oracle_compatible?(node, %Mut.Context{oracle_site: %DispatchSite{} = site} = ctx) do
    compatible?(candidate(node, ctx), site)
  end

  defp oracle_compatible?(_node, %Mut.Context{}), do: false

  defp candidate({op, meta, args} = node, ctx) do
    %AstCandidate{
      file: ctx.file,
      line: Keyword.get(meta, :line, 1),
      column: Keyword.get(meta, :column),
      syntactic_name: op,
      syntactic_arity: length(args),
      source_span: ctx.source_span,
      enclosing_module: ctx.enclosing_module,
      ast_path: ctx.ast_path,
      ast_path_hash: ctx.ast_path_hash,
      node: node
    }
  end

  defp build_mutations({op, meta, args} = node) do
    for replacement <- Map.fetch!(@replacements, op) do
      %Mutation{
        original_ast: node,
        mutated_ast: {replacement, meta, args},
        description: "replace #{op} with #{replacement}",
        mutation_kind: @kind,
        guard_safe?: true,
        metadata: %{operator: op, replacement: replacement}
      }
    end
  end
end
