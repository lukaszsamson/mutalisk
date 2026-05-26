defmodule Mut.Mutator.Pin do
  @moduledoc """
  M73 pattern-shape mutator. Removes a pin from a pattern:

    * `^x` → `x` (unpin)

  Unpinning turns a *constrained* match (must equal the already-bound value of
  `x`) into a plain rebind that always succeeds and shadows `x` — a real
  behavioural change a test can observe. Opt-in (`:pattern_shape`),
  fallback-routed (a source-span splice dropping the `^`).

  **M75 hazard rule (in `Mut.AstWalk.pin_candidates`): map-key pins are
  excluded.** `%{^k => v}` cannot be unpinned — `%{k => v}` is a compile error
  (pattern map keys must be literals or pinned). Without this, real code with
  `%{^key => …}` lookups (plug, jason) produced a ~30% invalid rate. Every
  other pin position (case/with/fn clause heads, map *values*, `=` matches)
  unpins cleanly.

  **Why this is the only pattern-shape mutator.** The other shapes the M39/M70
  sketch listed are non-viable by construction, joining tuple/list arity in the
  "skipped" set:

    * `var` → `_`: a compile error whenever the variable is used (body/guard),
      and behaviourally *equivalent* when it is unused — never a productive,
      compilable, non-equivalent mutant.
    * `_` → `var`: only introduces an unused binding — equivalent (plus an
      unused-variable warning).
    * `x` → `^x` (add pin): valid only when `x` is already bound in an enclosing
      scope (rare); in the common newly-bound case it is a compile error
      (undefined pinned variable). Deferred — the rare valid case is not worth
      the binding-scope analysis and false-positive risk.
  """
  @behaviour Mut.Mutator

  alias Mut.Mutation
  alias Mut.Oracle.AstCandidate
  alias Mut.Oracle.DispatchSite

  @kind :pin_removal

  @impl true
  def name, do: "Pin"

  @impl true
  def description, do: "Remove a pin from a pattern (^x -> x)."

  @impl true
  def targets, do: [:pattern_shape]

  @impl true
  def applicable?(node, %Mut.Context{} = ctx) do
    ctx.engine == :fallback and ctx.env_context == :match and pin?(node)
  end

  @impl true
  def mutate(node, %Mut.Context{} = ctx) do
    if applicable?(node, ctx), do: build_mutations(node), else: []
  end

  @impl true
  def equivalent?(_mutation), do: false

  @spec compatible?(AstCandidate.t(), DispatchSite.t() | nil) :: boolean
  def compatible?(%AstCandidate{} = candidate, _site), do: pin?(candidate.node)

  defp pin?({:^, _meta, [{name, _var_meta, ctx}]}) when is_atom(name) and is_atom(ctx), do: true
  defp pin?(_node), do: false

  defp build_mutations({:^, _meta, [inner]} = node) do
    [
      %Mutation{
        original_ast: node,
        mutated_ast: inner,
        description: "remove pin (^x -> x)",
        mutation_kind: @kind,
        guard_safe?: true,
        metadata: %{}
      }
    ]
  end
end
