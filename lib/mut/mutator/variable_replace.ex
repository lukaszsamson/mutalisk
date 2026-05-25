defmodule Mut.Mutator.VariableReplace do
  @moduledoc """
  M54 variable mutator. Replaces an in-scope variable *reference* (read) with
  another variable that is also in scope at that point.

  `Mut.EnvWalker.collect_variable_candidates/2` supplies the candidate's
  in-scope alternatives on `ctx.bound_vars` — a deliberate under-approximation
  (function parameters + enclosing clause-head bindings), so every replacement
  is a variable that is definitely bound at the reference. A swap therefore
  never introduces an *undefined* variable; the residual hazards are runtime
  behaviour (good — those mutants are killable) and the occasional
  "unused variable" warning, which `Mut.CompileRollback` removes under
  warnings-as-errors builds.

  **M57 noise refinement:** only fires when the swapped-out variable has ≥1
  OTHER read in the same function (`ctx.other_uses?`), so the swap leaves the
  name still used — no unused-variable churn. (`VariableToLiteral` does not
  require this; a sole-read boundary mutant is still useful.) Codegen functions
  (quote/unquote bodies) emit no variable candidates at all — see
  `Mut.EnvWalker`.

  Fallback-routed and opt-in (`--enable variable`). At most `@max_alternatives`
  swaps per reference (sorted) to bound mutant count.
  """

  @behaviour Mut.Mutator

  alias Mut.Mutation
  alias Mut.Oracle.AstCandidate
  alias Mut.Oracle.DispatchSite

  @max_alternatives 3

  @impl true
  def name, do: "VariableReplace"

  @impl true
  def description, do: "Replace an in-scope variable reference with another in-scope variable."

  @impl true
  def targets, do: [:variable]

  @impl true
  def applicable?(node, %Mut.Context{} = ctx) do
    ctx.env_context == nil and ctx.engine == :fallback and variable?(node) and
      alternatives(ctx) != [] and ctx.other_uses? == true
  end

  @impl true
  def mutate(node, %Mut.Context{} = ctx) do
    if applicable?(node, ctx), do: build_mutations(node, alternatives(ctx)), else: []
  end

  @impl true
  def equivalent?(_mutation), do: false

  @spec compatible?(AstCandidate.t(), DispatchSite.t() | nil) :: boolean
  def compatible?(%AstCandidate{} = candidate, _site), do: variable?(candidate.node)

  defp variable?({name, _meta, ctx}) when is_atom(name) and is_atom(ctx), do: true
  defp variable?(_), do: false

  defp alternatives(%Mut.Context{bound_vars: vars}) when is_list(vars), do: vars
  defp alternatives(_ctx), do: []

  defp build_mutations({name, meta, ctx} = node, alternatives) do
    alternatives
    |> Enum.reject(&(&1 == name))
    |> Enum.take(@max_alternatives)
    |> Enum.map(fn replacement ->
      %Mutation{
        original_ast: node,
        mutated_ast: {replacement, meta, ctx},
        description: "replace variable #{name} with #{replacement}",
        mutation_kind: :variable_replace,
        guard_safe?: false,
        metadata: %{from: name, to: replacement}
      }
    end)
  end
end
