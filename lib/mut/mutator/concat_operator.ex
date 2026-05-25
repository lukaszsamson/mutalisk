defmodule Mut.Mutator.ConcatOperator do
  @moduledoc """
  M69 operator-expansion mutator. Replaces list concatenation:

    * `++` → `--`

  **M72 hazard rule — the `--` → `++` direction is dropped.** M71 OSS data
  (jason) showed `--` → `++` is ~all noise: `--` (list subtraction) marks
  element-*removal* contexts (`fields -- [:__struct__]`, `only -- fields`),
  and replacing removal with concatenation produces invariant-breaking
  *larger* lists that crash downstream (suite-aborting `RuntimeError`) or
  compile-error in refused positions — not the subtly-wrong, test-catchable
  mutant we want. The reverse, `++` → `--`, turns concatenation into a
  smaller/empty list (the codegen.ex sites: one killed, two survived, zero
  noise), which is a productive, testable mutation. So only `++` is mutated.

  `<>` (binary concat) has no operator dual — a cross-type swap to `++`/`--`
  would be a guaranteed compile/type error — so it is not mutated. Opt-in,
  schema-routed (dispatch), mirroring `Mut.Mutator.Arithmetic`.
  """
  @behaviour Mut.Mutator

  alias Mut.Mutation
  alias Mut.Oracle.AstCandidate
  alias Mut.Oracle.DispatchSite

  @accepted_modules [Kernel, :erlang]
  @accepted_names ~w(++)a
  @arity 2
  @kind :concat_op
  @replacements %{:++ => [:--]}

  @impl true
  def name, do: "ConcatOperator"

  @impl true
  def description, do: "Swap list concatenation operators (++ <-> --)."

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
