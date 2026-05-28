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

  **M80 hazard rules (applied before emission):**

    * **Binding hazard.** When the condition contains an `=` match or `<-`
      (`if user = lookup(), do: f(user)`), `force true` / `force false`
      drop the binding and the body's `user` becomes undefined → compile
      error. Drove the ≈15% invalid rate on plug in M79. `negate` keeps the
      condition inside `not(...)`, so the binding survives — safe.
    * **Dead-branch hazard.** `if cond do body end` (no `else`) with
      `force false` skips the body and yields `nil`; the body is typically
      error-handling or a side-effect path that happy-path tests do not
      exercise, so the mutant survives as equivalent — drove the 25–52%
      dead-branch equivalence on jason/decimal/plug_crypto in M79.
      Symmetric on `unless`: `force true` is the no-else equivalent.

  `negate` is always emitted. The two `force` directions are gated.
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
    candidates = [
      {"negate", {:not, [], [cond]}, true},
      {"force true", true, not binds and not unless_no_else?(name, has_else)},
      {"force false", false, not binds and not if_no_else?(name, has_else)}
    ]

    for {label, replacement, emit?} <- candidates, emit? do
      mutation(node, name, replacement, label)
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
end
