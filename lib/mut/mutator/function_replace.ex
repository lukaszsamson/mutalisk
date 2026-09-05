defmodule Mut.Mutator.FunctionReplace do
  @moduledoc """
  M76 function-replacement mutator. Swaps a call to one stdlib function for its
  semantically-paired sibling, from a **closed allowlist** (never invents a
  target — the AtomLiteral closed-allowlist discipline).

  Each pair has the same module and arity and a meaningful behavioural
  difference a test should catch:

    * `Enum.min` ↔ `Enum.max`, `Enum.min_by` ↔ `Enum.max_by`
    * `Enum.all?` ↔ `Enum.any?`
    * `Enum.filter` ↔ `Enum.reject`
    * `Enum.take` ↔ `Enum.drop`
    * `List.first` ↔ `List.last`
    * `String.starts_with?` ↔ `String.ends_with?`
    * `String.first` ↔ `String.last`
    * `String.trim_leading` ↔ `String.trim_trailing`

  Schema-routed (`:dispatch`), opt-in, mirroring `Mut.Mutator.Arithmetic`. The
  swap fires only when the oracle confirms the dispatch resolves to the listed
  `{module, name, arity}` — so a shadowing local `min/1` or a same-named
  function in a different module is never swapped.
  """
  @behaviour Mut.Mutator

  alias Mut.Mutation
  alias Mut.Oracle.AstCandidate
  alias Mut.Oracle.DispatchSite

  @kind :function_replace

  # {resolved_module, resolved_name, resolved_arity} => replacement_name.
  # Closed allowlist: same module + arity, complementary behaviour.
  @swaps %{
    {Enum, :min, 1} => :max,
    {Enum, :max, 1} => :min,
    {Enum, :min, 2} => :max,
    {Enum, :max, 2} => :min,
    {Enum, :min_by, 2} => :max_by,
    {Enum, :max_by, 2} => :min_by,
    {Enum, :min_by, 3} => :max_by,
    {Enum, :max_by, 3} => :min_by,
    {Enum, :all?, 1} => :any?,
    {Enum, :any?, 1} => :all?,
    {Enum, :all?, 2} => :any?,
    {Enum, :any?, 2} => :all?,
    {Enum, :filter, 2} => :reject,
    {Enum, :reject, 2} => :filter,
    {Enum, :take, 2} => :drop,
    {Enum, :drop, 2} => :take,
    {List, :first, 1} => :last,
    {List, :last, 1} => :first,
    {String, :starts_with?, 2} => :ends_with?,
    {String, :ends_with?, 2} => :starts_with?,
    {String, :first, 1} => :last,
    {String, :last, 1} => :first,
    {String, :trim_leading, 1} => :trim_trailing,
    {String, :trim_trailing, 1} => :trim_leading,
    {String, :trim_leading, 2} => :trim_trailing,
    {String, :trim_trailing, 2} => :trim_leading
  }

  # M103 measured but did NOT add: `Enum.sort`↔`reverse`,
  # `Enum.take_while`↔`drop_while`, `String.upcase`↔`downcase`,
  # `Map.put`↔`put_new`. All invalid-safe (same module/arity), but the matrix
  # measurement found no kill-signal on the available targets (jason added 2
  # candidates, both equivalent; bandit added 0) — insufficient evidence to
  # ship into a default-on surface, where equivalent mutants would depress
  # users' scores. Held as candidates for a future cycle with richer targets.

  @impl true
  def name, do: "FunctionReplace"

  @impl true
  def description, do: "Swap a stdlib function for its paired sibling (closed allowlist)."

  @impl true
  def targets, do: [:dispatch]

  @impl true
  def applicable?(node, %Mut.Context{} = ctx) do
    ctx.env_context == nil and call_shape?(node) and oracle_compatible?(node, ctx)
  end

  @impl true
  def mutate(node, %Mut.Context{oracle_site: %DispatchSite{} = site} = ctx) do
    if applicable?(node, ctx), do: build_mutations(node, site), else: []
  end

  def mutate(_node, %Mut.Context{}), do: []

  @impl true
  def equivalent?(_mutation), do: false

  @spec compatible?(AstCandidate.t(), DispatchSite.t()) :: boolean
  def compatible?(%AstCandidate{} = candidate, %DispatchSite{} = site) do
    candidate.syntactic_name == site.resolved_name and
      candidate.syntactic_arity == site.resolved_arity and
      Map.has_key?(@swaps, {site.resolved_module, site.resolved_name, site.resolved_arity})
  end

  # Remote call `Mod.fun(args)` or imported/bare `fun(args)`.
  defp call_shape?({{:., _dm, [_target, name]}, _m, args})
       when is_atom(name) and is_list(args),
       do: true

  defp call_shape?({name, _m, args}) when is_atom(name) and is_list(args), do: true
  defp call_shape?(_node), do: false

  defp oracle_compatible?(node, %Mut.Context{oracle_site: %DispatchSite{} = site} = ctx) do
    compatible?(candidate(node, ctx), site)
  end

  defp oracle_compatible?(_node, %Mut.Context{}), do: false

  defp candidate(node, ctx) do
    {syntactic_name, arity} = name_arity(node)

    %AstCandidate{
      file: ctx.file,
      line: ctx.source_span && ctx.source_span.start_line,
      column: ctx.source_span && ctx.source_span.start_column,
      syntactic_name: syntactic_name,
      syntactic_arity: arity,
      source_span: ctx.source_span,
      enclosing_module: ctx.enclosing_module,
      ast_path: ctx.ast_path,
      ast_path_hash: ctx.ast_path_hash,
      node: node
    }
  end

  defp name_arity({{:., _dm, [_target, name]}, _m, args}), do: {name, length(args)}
  defp name_arity({name, _m, args}), do: {name, length(args)}

  defp build_mutations(node, %DispatchSite{} = site) do
    replacement =
      Map.fetch!(@swaps, {site.resolved_module, site.resolved_name, site.resolved_arity})

    [
      %Mutation{
        original_ast: node,
        mutated_ast: rename(node, replacement, site),
        description: "replace #{site.resolved_name} with #{replacement}",
        mutation_kind: @kind,
        guard_safe?: true,
        metadata: %{
          module: site.resolved_module,
          function: site.resolved_name,
          replacement: replacement
        }
      }
    ]
  end

  # Remote call `Mod.fun(args)`: rename in place, target untouched.
  defp rename({{:., dm, [target, _name]}, m, args}, replacement, _site),
    do: {{:., dm, [target, replacement]}, m, args}

  # Bare imported call `fun(args)` resolved via an `import`: the replacement
  # name may not be in the caller's import list (e.g. `import Enum, only:
  # [filter: 2]` does not bring `reject/2` into scope), so a bare rename can
  # produce a mutant that fails to compile for a reason unrelated to the
  # mutation itself. Emit a fully-qualified call instead — it compiles
  # regardless of what was imported. Only functions: a qualified MACRO call
  # would additionally need `require`, and the swap allowlist contains no
  # macros anyway.
  defp rename({_name, m, args}, replacement, %DispatchSite{
         dispatch_kind: :imported_function,
         resolved_module: module
       })
       when not is_nil(module) do
    target = {:__aliases__, [alias: false], Module.split(module) |> Enum.map(&String.to_atom/1)}
    {{:., [], [target, replacement]}, m, args}
  end

  # Any other bare call (e.g. local function): rename in place, as before.
  defp rename({_name, m, args}, replacement, _site), do: {replacement, m, args}
end
