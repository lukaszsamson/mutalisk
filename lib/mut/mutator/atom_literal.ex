defmodule Mut.Mutator.AtomLiteral do
  @moduledoc """
  M45 env-walker literal mutator. Replaces body-context atom literals
  from a **closed allowlist** of swaps.

  ## Atom-table-pollution policy (designed before code)

  Mutating atoms is dangerous if done generically: an arbitrary atom →
  arbitrary atom swap pollutes the atom table, creates near-infinite
  equivalent mutants, and rarely maps to a behavioural fault a test can
  catch. This mutator therefore obeys two hard rules:

    1. **Never synthesize a new atom.** Every replacement is itself a key
       of the allowlist, so the set of atoms the mutator can introduce is
       finite and known at compile time.
    2. **Closed allowlist only.** Atoms outside the table are left
       untouched (the candidate becomes a `:no_applicable_mutator` skip).

  The allowlist targets the two atom conventions whose misuse a
  well-written suite should detect — the ok/error result tag and the
  three-way comparison result:

      :ok    -> :error
      :error -> :ok
      :lt    -> :gt, :eq
      :gt    -> :lt, :eq
      :eq    -> :lt, :gt

  `true` / `false` are intentionally excluded — `BooleanLiteral` owns
  them — and `nil` is owned by `NilLiteral`. Fallback-routed and opt-in
  (`--enable env_walker`).
  """

  @behaviour Mut.Mutator

  alias Mut.Mutation
  alias Mut.Oracle.AstCandidate
  alias Mut.Oracle.DispatchSite

  @allowlist %{
    ok: [:error],
    error: [:ok],
    lt: [:gt, :eq],
    gt: [:lt, :eq],
    eq: [:lt, :gt]
  }

  @impl true
  def name, do: "AtomLiteral"

  @impl true
  def description, do: "Replace allowlisted atom literal in function body."

  @impl true
  def targets, do: [:env_walker, :pattern_literal]

  @impl true
  def applicable?(node, %Mut.Context{} = ctx) do
    ctx.env_context in [nil, :match] and ctx.engine in [:fallback, :schema] and
      allowlisted_atom?(node)
  end

  @impl true
  def mutate(node, %Mut.Context{} = ctx) do
    if applicable?(node, ctx), do: build_mutations(node), else: []
  end

  @impl true
  def equivalent?(%Mutation{metadata: %{from: from, to: to}}), do: from == to
  def equivalent?(_mutation), do: false

  @spec compatible?(AstCandidate.t(), DispatchSite.t() | nil) :: boolean
  def compatible?(%AstCandidate{} = candidate, _site) do
    allowlisted_atom?(candidate.node)
  end

  defp allowlisted_atom?({:__block__, _meta, [value]}) when is_atom(value),
    do: Map.has_key?(@allowlist, value)

  defp allowlisted_atom?(_), do: false

  defp build_mutations({:__block__, meta, [value]} = node) do
    @allowlist
    |> Map.fetch!(value)
    |> Enum.map(fn replacement ->
      %Mutation{
        original_ast: node,
        mutated_ast: {:__block__, meta, [replacement]},
        description: "replace atom literal #{inspect(value)} with #{inspect(replacement)}",
        mutation_kind: :atom_literal,
        guard_safe?: false,
        metadata: %{from: value, to: replacement}
      }
    end)
  end
end
