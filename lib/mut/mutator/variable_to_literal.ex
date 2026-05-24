defmodule Mut.Mutator.VariableToLiteral do
  @moduledoc """
  M56 variable mutator. Replaces an in-scope variable *reference* (read) with a
  boundary literal of the variable's syntactically-evident type.

  The type is inferred purely from the AST (no macro expansion, no inference —
  M39 contract): `Mut.EnvWalker` threads a `type_hint` to a variable that is a
  DIRECT operand of a type-determining operator. The hint is shallow —
  `a + 1` hints `a` numeric, but `f(x) + 1` does NOT hint `x` (that would infer
  through `f/1`). Current hint coverage (deliberately narrow per review):

    * `:number`  (`+ - * /`)        -> `0`
    * `:binary`  (`<>`)             -> `""`
    * `:list`    (`++` / `--`)      -> `[]`

  Fallback-routed. **Opt-in via explicit `--mutators variable_to_literal`** — it
  is intentionally absent from `Mut.Mutator.Defaults.list/0`, so `--enable
  variable` (which runs `VariableReplace`) does NOT silently gain it.

  Boundary literals are frequently *equivalent* when tests already exercise
  boundary-valued inputs; that equivalent rate is the keep/cut metric for this
  mutator (see `docs/decisions/M56_variable_to_literal_PLAN.md`).
  """

  @behaviour Mut.Mutator

  alias Mut.Mutation
  alias Mut.Oracle.AstCandidate
  alias Mut.Oracle.DispatchSite

  @boundaries %{number: 0, binary: "", list: []}

  @impl true
  def name, do: "VariableToLiteral"

  @impl true
  def description, do: "Replace an in-scope variable reference with a boundary literal."

  @impl true
  def targets, do: [:variable]

  @impl true
  def applicable?(node, %Mut.Context{} = ctx) do
    ctx.env_context == nil and ctx.engine == :fallback and variable?(node) and
      Map.has_key?(@boundaries, ctx.type_hint)
  end

  @impl true
  def mutate(node, %Mut.Context{} = ctx) do
    if applicable?(node, ctx), do: build_mutation(node, ctx.type_hint), else: []
  end

  @impl true
  def equivalent?(_mutation), do: false

  @spec compatible?(AstCandidate.t(), DispatchSite.t() | nil) :: boolean
  def compatible?(%AstCandidate{} = candidate, _site), do: variable?(candidate.node)

  defp variable?({name, _meta, ctx}) when is_atom(name) and is_atom(ctx), do: true
  defp variable?(_), do: false

  defp build_mutation({name, _meta, _ctx} = node, hint) do
    literal = Map.fetch!(@boundaries, hint)

    [
      %Mutation{
        original_ast: node,
        mutated_ast: literal,
        description: "replace variable #{name} with #{inspect(literal)}",
        mutation_kind: :variable_to_literal,
        guard_safe?: false,
        metadata: %{from: name, to: literal, hint: hint}
      }
    ]
  end
end
