defmodule Mut.Mutator.NilLiteral do
  @moduledoc """
  M44 env-walker literal mutator. Replaces `nil` body literals with a
  sentinel atom.

  Replacement table (closed, single replacement):

    * `nil` → `:__mut_nil__`

  Eligibility mirrors `Mut.Mutator.StringLiteral` (M39 binding):
  the site is in `scope: :function_body`, `context: nil`,
  `trust_level: :trusted`, and the literal is `nil`. Because the
  candidate's `env_context` must be `nil` (normal expression),
  `nil` literals in match and guard positions are never reached.

  A sentinel — not `true`/`false` or another concrete value — keeps
  the mutation semantically distinct from `BooleanLiteral` while
  guaranteeing the mutated value differs from the original. Fallback-
  routed and opt-in (`--enable env_walker`).
  """

  @behaviour Mut.Mutator

  alias Mut.Mutation
  alias Mut.Oracle.AstCandidate
  alias Mut.Oracle.DispatchSite

  @sentinel :__mut_nil__

  @impl true
  def name, do: "NilLiteral"

  @impl true
  def description, do: "Replace nil literal in function body."

  @impl true
  def targets, do: [:env_walker]

  @impl true
  def applicable?(node, %Mut.Context{} = ctx) do
    ctx.env_context == nil and ctx.engine in [:fallback, :schema] and nil_literal?(node)
  end

  @impl true
  def mutate(node, %Mut.Context{} = ctx) do
    if applicable?(node, ctx), do: build_mutations(node), else: []
  end

  @impl true
  def equivalent?(_mutation), do: false

  @spec compatible?(AstCandidate.t(), DispatchSite.t() | nil) :: boolean
  def compatible?(%AstCandidate{} = candidate, _site) do
    nil_literal?(candidate.node)
  end

  defp nil_literal?({:__block__, _meta, [value]}), do: is_nil(value)
  defp nil_literal?(_), do: false

  defp build_mutations({:__block__, meta, [nil]} = node) do
    [
      %Mutation{
        original_ast: node,
        mutated_ast: {:__block__, meta, [@sentinel]},
        description: "replace nil literal with #{inspect(@sentinel)}",
        mutation_kind: :nil_literal,
        guard_safe?: false,
        metadata: %{from: nil, to: @sentinel}
      }
    ]
  end
end
