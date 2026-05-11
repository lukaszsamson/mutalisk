defmodule Mut.Mutator.StringLiteral do
  @moduledoc """
  M40 first env-walker-backed mutator. Replaces non-empty string
  body literals with `""`. Fallback-routed (M39 stable-id strategy:
  no schema-routing migration in v1.14).

  Eligibility (M39 binding):

    * The mutation site is in `scope: :function_body`.
    * The mutation site is in `context: nil` (normal expression).
    * The mutation site has `trust_level: :trusted`.
    * The literal value is a non-empty binary.
    * Interpolated strings (`"x" <> inspect(y)` shape) are NOT eligible —
      M39 mutator-ordering item 6 defers source-span replacement
      for interpolated content to v1.15+.

  The walker (`Mut.EnvWalker.collect_string_literal_candidates/2`)
  enforces all four eligibility conditions before this mutator
  sees a candidate. `applicable?/2` also checks defensively so
  the mutator is correct when called directly.

  ## Routing

  Targets `:env_walker` exclusively. Body-literal candidates
  produced by the existing `Mut.AstWalk.body_literal_candidates/1`
  walker do NOT reach this mutator — string literals are out of
  the M23 integer/boolean scope by design.
  """

  @behaviour Mut.Mutator

  alias Mut.Mutation
  alias Mut.Oracle.AstCandidate
  alias Mut.Oracle.DispatchSite

  @impl true
  def name, do: "StringLiteral"

  @impl true
  def description, do: "Replace non-empty string body literal."

  @impl true
  def targets, do: [:env_walker]

  @impl true
  def applicable?(node, %Mut.Context{} = ctx) do
    ctx.env_context == nil and ctx.engine == :fallback and non_empty_string_literal?(node)
  end

  @impl true
  def mutate(node, %Mut.Context{} = ctx) do
    if applicable?(node, ctx), do: build_mutations(node), else: []
  end

  @impl true
  def equivalent?(_mutation), do: false

  @spec compatible?(AstCandidate.t(), DispatchSite.t() | nil) :: boolean
  def compatible?(%AstCandidate{} = candidate, _site) do
    non_empty_string_literal?(candidate.node)
  end

  defp non_empty_string_literal?({:__block__, _meta, [value]})
       when is_binary(value) and value != "",
       do: true

  defp non_empty_string_literal?(_), do: false

  defp build_mutations({:__block__, meta, [value]} = node) when is_binary(value) do
    [
      %Mutation{
        original_ast: node,
        mutated_ast: {:__block__, meta, [""]},
        description: "replace non-empty string literal with \"\"",
        mutation_kind: :string_literal,
        guard_safe?: false,
        metadata: %{from: value, to: ""}
      }
    ]
  end
end
