defmodule Mut.Mutator.Membership do
  @moduledoc """
  M69 operator-expansion mutator. Negates membership tests: `x in y` becomes
  `x not in y`, and `x not in y` becomes `x in y`.

  `x not in y` parses as `not(x in y)`, so the two directions target different
  nodes: the plain `in` node is wrapped in `not` (dispatch on `Kernel.in/2`),
  while a `not`-wrapped `in` is mutated by *unwrapping* it (dispatch on
  `Kernel.not/1`). Negating the inner `in` of a `not in` instead would render
  `not(not(x in y))` on the schema path and splice `x not not(x in y)` on the
  fallback span path (B20), so that inner candidate is suppressed.

  Unlike the arithmetic/bitwise swaps this is a STRUCTURAL mutation (wrap or
  unwrap a `not` node), not an operator-name swap. Opt-in, schema-routed.
  """
  @behaviour Mut.Mutator

  alias Mut.Mutation
  alias Mut.Oracle.AstCandidate
  alias Mut.Oracle.DispatchSite

  @accepted_modules [Kernel]
  @accepted_not_modules [Kernel, :erlang]
  @accepted_names [:in]
  @arity 2
  @kind :membership_op

  @impl true
  def name, do: "Membership"

  @impl true
  def description, do: "Negate membership tests (in <-> not in)."

  @impl true
  def targets, do: [:dispatch]

  @impl true
  def applicable?(node, %Mut.Context{} = ctx) do
    ctx.env_context == nil and shape_matches?(node, ctx.ast_path) and
      oracle_compatible?(node, ctx)
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
      accepted_site?(site, candidate)
  end

  defp accepted_site?(%DispatchSite{resolved_name: :not} = site, candidate) do
    site.resolved_module in @accepted_not_modules and not_in_node?(candidate.node)
  end

  defp accepted_site?(%DispatchSite{} = site, _candidate) do
    site.resolved_module in @accepted_modules and site.resolved_name in @accepted_names
  end

  defp not_in_node?({:not, _meta, [{:in, _in_meta, args}]}) when length(args) == @arity, do: true
  defp not_in_node?(_node), do: false

  # The `in` of a `not in` is skipped: the enclosing `not` carries the mutation.
  defp shape_matches?({:in, _meta, args}, ast_path) when length(args) == @arity,
    do: not negated_in_path?(ast_path)

  defp shape_matches?(node, _ast_path), do: not_in_node?(node)

  defp negated_in_path?(ast_path) when is_list(ast_path),
    do: List.last(ast_path) == {:elem, :not, 0}

  defp negated_in_path?(_ast_path), do: false

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

  defp build_mutations({:in, meta, _args} = node) do
    [
      %Mutation{
        original_ast: node,
        mutated_ast: {:not, meta, [node]},
        description: "negate membership (in -> not in)",
        mutation_kind: @kind,
        guard_safe?: true,
        metadata: %{operator: :in, replacement: :not_in}
      }
    ]
  end

  defp build_mutations({:not, _meta, [{:in, _in_meta, _args} = in_node]} = node) do
    [
      %Mutation{
        original_ast: node,
        mutated_ast: in_node,
        description: "negate membership (not in -> in)",
        mutation_kind: @kind,
        guard_safe?: true,
        metadata: %{operator: :not_in, replacement: :in}
      }
    ]
  end
end
