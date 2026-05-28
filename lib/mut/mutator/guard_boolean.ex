defmodule Mut.Mutator.GuardBoolean do
  @moduledoc """
  M90 guard-boolean mutator. Existing `Guard*` mutators cover comparison and
  type-test operators inside `when` guards; this closes the small catalogue
  gap for the boolean connectives that are guard-safe:

    * `and` <-> `or` (the strict, guard-safe forms — `&&`/`||` are short-
      circuit operators and not permitted in guards).
    * `not x` -> `x` (remove the negation — flips the guard polarity).

  Fallback-routed via the existing guard machinery; the candidate's
  `env_context` is `:guard` (set by `Mut.AstWalk` when walking dispatch sites
  in guard position). Opt-in via a **dedicated target `:guard_boolean`** —
  *not* `:guard`, so the existing default-on guard mutators (comparison
  +/- type-test) keep firing without `--enable`, and GuardBoolean fires only
  under explicit `--enable guard_boolean` (or once M93 graduates it, by
  adding `:guard_boolean` to `@default_enabled_targets`). Without that
  gate, adding GuardBoolean to `@opt_in` would make it fire by default —
  `:guard` is the only default-enabled target that's also fallback-engine,
  so the standard "new opt-in target keeps it gated" pattern needs to apply
  here too.

  *Out of scope:* `&&`/`||` (not guard-safe — `Mut.Mutator.Boolean` covers
  these in body position only); `xor` (rarely used, no clear semantic swap).
  """
  @behaviour Mut.Mutator

  alias Mut.Mutation
  alias Mut.Oracle.AstCandidate
  alias Mut.Oracle.DispatchSite

  @accepted_modules [Kernel, :erlang]
  @swap_names ~w(and or)a
  @not_name :not
  @accepted_names [@not_name | @swap_names]
  @kind :guard_boolean
  @swap_replacements %{and: [:or], or: [:and]}

  @impl true
  def name, do: "GuardBoolean"

  @impl true
  def description, do: "Swap guard `and`/`or`; drop guard `not`."

  @impl true
  def targets, do: [:guard_boolean]

  @impl true
  def applicable?(node, %Mut.Context{} = ctx) do
    ctx.env_context == :guard and ctx.engine == :fallback and shape_matches?(node)
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

  defp shape_matches?({op, _meta, args}) when op in @swap_names and length(args) == 2, do: true
  defp shape_matches?({@not_name, _meta, [_x]}), do: true
  defp shape_matches?(_node), do: false

  defp build_mutations({op, meta, args} = node) when op in @swap_names do
    for replacement <- Map.fetch!(@swap_replacements, op) do
      %Mutation{
        original_ast: node,
        mutated_ast: {replacement, meta, args},
        description: "replace guard #{op} with #{replacement}",
        mutation_kind: @kind,
        guard_safe?: true,
        metadata: %{operator: op, replacement: replacement}
      }
    end
  end

  defp build_mutations({@not_name, _meta, [inner]} = node) do
    [
      %Mutation{
        original_ast: node,
        mutated_ast: inner,
        description: "drop guard not",
        mutation_kind: @kind,
        guard_safe?: true,
        metadata: %{operator: :not, replacement: :drop}
      }
    ]
  end
end
