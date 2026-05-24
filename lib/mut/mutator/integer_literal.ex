defmodule Mut.Mutator.IntegerLiteral do
  @moduledoc """
  M23: Replace integer literals in function-body context.

  Replacement table:

    * `0` → `1`
    * `1` → `0`
    * `n` → `0`        (for n outside {0, 1})
    * `n` → `n + 1`    (for n outside {0, 1}; integer overflow not a
      practical concern in Elixir's bignum world but the description
      records the intent)

  Only applies when the candidate is in body position (no env_context)
  and the engine is `:fallback`. Body literals route through the
  fallback engine because schema instrumentation requires
  `literal_encoder` parsing globally — see PLAN.md M23 notes.
  """
  @behaviour Mut.Mutator

  alias Mut.Mutation
  alias Mut.Oracle.AstCandidate
  alias Mut.Oracle.DispatchSite

  @impl true
  def name, do: "IntegerLiteral"

  @impl true
  def description, do: "Replace integer literal in function body."

  @impl true
  def targets, do: [:body_literal, :pattern_literal]

  @impl true
  def applicable?(node, %Mut.Context{} = ctx) do
    ctx.env_context in [nil, :match] and ctx.engine in [:fallback, :schema] and
      integer_literal?(node)
  end

  @impl true
  def mutate(node, %Mut.Context{} = ctx) do
    if applicable?(node, ctx), do: build_mutations(node), else: []
  end

  @impl true
  def equivalent?(_mutation), do: false

  @spec compatible?(AstCandidate.t(), DispatchSite.t() | nil) :: boolean
  def compatible?(%AstCandidate{} = candidate, _site) do
    integer_literal?(candidate.node)
  end

  defp integer_literal?({:__block__, _meta, [value]}) when is_integer(value), do: true
  defp integer_literal?(_), do: false

  defp build_mutations({:__block__, _meta, [value]} = node) do
    value
    |> replacements()
    |> Enum.map(fn replacement ->
      %Mutation{
        original_ast: node,
        # Strip parser meta (especially `:token`, which Macro.to_string
        # would echo verbatim and defeat the mutation). Keep the
        # mutated value as a bare literal so FallbackPatch.render
        # produces the new source text.
        mutated_ast: replacement,
        description: "replace integer literal #{value} with #{replacement}",
        mutation_kind: :integer_literal_replace,
        guard_safe?: false,
        metadata: %{original_value: value, replacement_value: replacement}
      }
    end)
  end

  defp replacements(0), do: [1]
  defp replacements(1), do: [0]
  defp replacements(n) when is_integer(n), do: [0, n + 1]
end
