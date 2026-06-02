defmodule Mut.Mutator.NegateConditional do
  @moduledoc """
  M77 conditional mutator — the classic top-yield branch mutator. Mutates the
  condition of an `if`/`unless`:

    * **negate**: `cond` → `!(cond)`
    * **force true**: `cond` → `true`
    * **force false**: `cond` → `false`

  Negate uses the truthy `!` (not the strict-boolean `not`): an `if`/`unless`
  condition is evaluated for truthiness, and `!` negates any term safely,
  whereas `not` raises `ArgumentError` on a non-boolean. This matters for a
  binding condition like `if {:ok, v} = fetch()` — `not({:ok, v} = fetch())`
  would crash on the tuple, but `!({:ok, v} = fetch())` negates the match's
  truthiness while still binding `v`, yielding a productive mutant.

  These three are the same for `if` and `unless` (the condition is a boolean
  expression; the `if`/`unless` wrapper is preserved). Opt-in (`:conditional`),
  fallback-routed: the candidate's node is the whole `if`/`unless` (block form,
  spanned via its `:end` metadata) and each mutation re-emits that node with the
  condition replaced, so the branches are preserved verbatim.

  **M80 hazard rules (applied before emission):**

    * **Binding hazard.** When the condition contains an `=` match or `<-`
      (`if user = lookup(), do: f(user)`), `force true` / `force false`
      drop the binding and the body's `user` becomes undefined → compile
      error. Drove the ≈15% invalid rate on plug in M79. `negate` keeps the
      condition inside `!(...)`, so the binding survives *and* (using the
      truthy `!`, not the strict-boolean `not`) it does not crash on a
      non-boolean match result — safe and productive.
    * **Dead-branch hazard.** `if cond do body end` (no `else`) with
      `force false` skips the body and yields `nil`; the body is typically
      error-handling or a side-effect path that happy-path tests do not
      exercise, so the mutant survives as equivalent — drove the 25–52%
      dead-branch equivalence on jason/decimal/plug_crypto in M79.
      Symmetric on `unless`: `force true` is the no-else equivalent.

  **M89 hazard rule (added on the v1.24 carry):**

    * **Symmetric-branches hazard.** When both branches are structurally
      identical (`if cond do A else A end` after stripping metadata),
      every mutation is observationally equivalent to the original:
      `negate` still picks A; `force true`/`false` both pick A. The
      surface generates pure noise. Skip all three. This caught the
      jason survivors that the M80 no-else gate did not — symmetric
      branches that compute the same observable.

  `negate` is always emitted (subject to symmetric-branches gate).
  The two `force` directions are gated.
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

  defp build_mutations({name, _meta, [cond, kw]} = node) do
    has_else = Keyword.has_key?(kw, :else)
    binds = cond_introduces_binding?(cond)

    # M80 hazards (gate before emission):
    #   * binding hazard — `if user = lookup(id), do: f(user)` becomes
    #     `if true, do: f(user)` (or `false, ...`); the binding is lost and
    #     `user` is undefined => 15.3%-invalid class on plug. negate keeps
    #     the binding inside `not(...)`, so it is safe.
    #   * dead-branch hazard — `if cond do body end` (no else): force-false
    #     skips the body and yields nil; happy-path tests rarely exercise
    #     the body, so this becomes the dominant equivalent class
    #     (25–52% on jason/decimal/plug_crypto). Symmetric on `unless`.
    #
    # M89 hazard (symmetric-branches): if both branches are structurally
    # identical after metadata stripping, all three mutations are
    # equivalent to the original — surface generates pure noise. Skip all.
    if symmetric_branches?(kw) do
      []
    else
      candidates = [
        {"negate", {:!, [], [cond]}, true},
        {"force true", true, not binds and not unless_no_else?(name, has_else)},
        {"force false", false, not binds and not if_no_else?(name, has_else)}
      ]

      for {label, replacement, emit?} <- candidates, emit? do
        mutation(node, name, replacement, label)
      end
    end
  end

  defp mutation({name, meta, [_cond, kw]} = node, name, replacement, label) do
    %Mutation{
      original_ast: node,
      mutated_ast: {name, meta, [replacement, kw]},
      description: "#{name} condition: #{label}",
      mutation_kind: @kind,
      guard_safe?: true,
      metadata: %{control_flow: name, change: label}
    }
  end

  defp if_no_else?(:if, has_else), do: not has_else
  defp if_no_else?(_, _), do: false

  defp unless_no_else?(:unless, has_else), do: not has_else
  defp unless_no_else?(_, _), do: false

  # Does the condition introduce a binding that the body would reference?
  # Conservative: any `=` match or `<-` (with/for) anywhere in the condition
  # is treated as a binding hazard. Catches the idiomatic
  # `if x = lookup(), do: f(x)`; over-includes a bit (some `=` patterns the
  # body doesn't read), at the cost of slightly fewer force-* mutants.
  defp cond_introduces_binding?(cond_ast) do
    {_ast, found?} =
      Macro.prewalk(cond_ast, false, fn
        {:=, _meta, [_lhs, _rhs]} = node, _acc -> {node, true}
        {:<-, _meta, _args} = node, _acc -> {node, true}
        node, acc -> {node, acc}
      end)

    found?
  end

  # M89 symmetric-branches hazard: branches structurally identical after
  # metadata stripping. Conservative on shape: needs an `:else` branch to be
  # comparable at all (no-else handled by the dead-branch gate). Compares
  # the do-branch's body to the else-branch's body via Macro.escape of an
  # untyped AST round-trip — but the cheap form is just structural equality
  # on the `:do` and `:else` values after pruning metadata leaves.
  defp symmetric_branches?(kw) do
    with do_branch when not is_nil(do_branch) <- Keyword.get(kw, :do),
         else_branch when not is_nil(else_branch) <- Keyword.get(kw, :else) do
      strip_meta(do_branch) == strip_meta(else_branch)
    else
      _ -> false
    end
  end

  # Recursively normalize AST by clearing metadata on every {atom, meta, args}
  # tuple, so structurally-identical-but-positionally-different branches
  # compare equal. Leaves (literals, vars-with-context atoms) pass through.
  defp strip_meta({form, _meta, args}) when is_atom(form) or is_tuple(form) do
    {strip_meta(form), [], strip_meta(args)}
  end

  defp strip_meta(list) when is_list(list), do: Enum.map(list, &strip_meta/1)
  defp strip_meta({a, b}), do: {strip_meta(a), strip_meta(b)}
  defp strip_meta(other), do: other
end
