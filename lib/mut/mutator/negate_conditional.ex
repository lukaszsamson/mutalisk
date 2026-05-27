defmodule Mut.Mutator.NegateConditional do
  @moduledoc """
  M77 conditional mutator — the classic top-yield branch mutator. Mutates the
  condition of an `if`/`unless`:

    * **negate**: `cond` → `not(cond)`
    * **force true**: `cond` → `true`
    * **force false**: `cond` → `false`

  These three are the same for `if` and `unless` (the condition is a boolean
  expression; the `if`/`unless` wrapper is preserved). Opt-in (`:conditional`),
  fallback-routed: the candidate's node is the whole `if`/`unless` (block form,
  spanned via its `:end` metadata) and each mutation re-emits that node with the
  condition replaced, so the branches are preserved verbatim.

  **Dead-branch equivalence (measured, not gated here):** forcing a branch the
  code does not rely on is equivalent — e.g. an `if cond do X end` with no
  `else`, used only for its side effect, where `force true` keeps X and `force
  false` yields `nil`. Whether that is observable depends on the surrounding
  code, which is not decidable syntactically; M79 measures the equivalent-rate
  (covered-survivors) and the graduation decision accounts for it.
  """
  @behaviour Mut.Mutator

  alias Mut.Mutation
  alias Mut.Oracle.AstCandidate
  alias Mut.Oracle.DispatchSite

  @kind :negate_conditional

  @impl true
  def name, do: "NegateConditional"

  @impl true
  def description, do: "Negate / force if/unless conditions."

  @impl true
  def targets, do: [:conditional]

  @impl true
  def applicable?(node, %Mut.Context{} = ctx) do
    ctx.engine == :fallback and conditional?(node)
  end

  @impl true
  def mutate(node, %Mut.Context{} = ctx) do
    if applicable?(node, ctx), do: build_mutations(node), else: []
  end

  @impl true
  def equivalent?(_mutation), do: false

  @spec compatible?(AstCandidate.t(), DispatchSite.t() | nil) :: boolean
  def compatible?(%AstCandidate{} = candidate, _site), do: conditional?(candidate.node)

  defp conditional?({name, _meta, [_cond, kw]}) when name in [:if, :unless] and is_list(kw),
    do: Keyword.keyword?(kw) and Keyword.has_key?(kw, :do)

  defp conditional?(_node), do: false

  defp build_mutations({name, meta, [cond, kw]} = node) do
    for {label, replacement} <- [
          {"negate", {:not, [], [cond]}},
          {"force true", true},
          {"force false", false}
        ] do
      %Mutation{
        original_ast: node,
        mutated_ast: {name, meta, [replacement, kw]},
        description: "#{name} condition: #{label}",
        mutation_kind: @kind,
        guard_safe?: true,
        metadata: %{control_flow: name, change: label}
      }
    end
  end
end
