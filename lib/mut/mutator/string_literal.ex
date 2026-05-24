defmodule Mut.Mutator.StringLiteral do
  @moduledoc """
  M40 first env-walker-backed mutator. Replaces non-empty string
  body literals. Fallback-routed (M39 stable-id strategy: no
  schema-routing migration in v1.14).

  Replacement table (behind the env-walker opt-in):

    * `s` → `""`            (M40 original)
    * `s` → `"x"`           (M44; skipped when `s == "x"`)

  Each replacement is a distinct mutant with distinct `to` metadata,
  so adding/removing a row never churns the others' stable IDs.
  M49 dropped the M44 prepend-space row (`s → " " <> s`): M46 execution
  showed it was equivalent-heavy and dragged the kill rate. Interpolated
  strings remain out of scope (M39 item 6; M41 recorded no demand).

  Eligibility (M39 binding):

    * The mutation site is in `scope: :function_body`.
    * The mutation site is in `context: nil` (normal expression).
    * The mutation site has `trust_level: :trusted`.
    * The literal value is a non-empty binary.
    * Interpolated strings (`"x" <> inspect(y)` shape) are NOT eligible —
      M39 mutator-ordering item 6 defers source-span replacement
      for interpolated content to v1.15+.

  The walker (`Mut.EnvWalker.collect_literal_candidates/2`)
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
  def targets, do: [:env_walker, :pattern_literal]

  @impl true
  def applicable?(node, %Mut.Context{} = ctx) do
    ctx.env_context in [nil, :match] and ctx.engine in [:fallback, :schema] and
      non_empty_string_literal?(node)
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
    non_empty_string_literal?(candidate.node)
  end

  defp non_empty_string_literal?({:__block__, _meta, [value]})
       when is_binary(value) and value != "",
       do: true

  defp non_empty_string_literal?(_), do: false

  defp build_mutations({:__block__, meta, [value]} = node) when is_binary(value) do
    Enum.map(replacements(), fn {to, description} ->
      %Mutation{
        original_ast: node,
        mutated_ast: {:__block__, meta, [to]},
        description: description,
        mutation_kind: :string_literal,
        guard_safe?: false,
        metadata: %{from: value, to: to}
      }
    end)
  end

  # The `→ ""` and `→ "x"` rows are unchanged so their metadata — and
  # therefore their stable IDs — are byte-identical across releases. The
  # `→ "x"` row collapses to a no-op via `equivalent?/1` when the source
  # value is already "x". M49 dropped the M44 prepend-space row
  # (`s → " " <> s`): execution showed it was equivalent-heavy and dragged
  # the kill rate (see docs/decisions/M46_string_literal_table.md).
  defp replacements do
    [
      {"", "replace non-empty string literal with \"\""},
      {"x", "replace non-empty string literal with \"x\""}
    ]
  end
end
