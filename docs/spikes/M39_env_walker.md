# M39 - Env Walker Design Spike

**Status:** decision committed.
**Date:** 2026-05-11.
**Author:** v1.13 M39 spike.

## Question

Design a lean source-AST walker that gives mutalisk enough environment
context for v2 mutators without reimplementing the Elixir compiler.

The walker must answer, for source nodes that may become mutation sites:

- Is the node in normal expression context, match context, or guard context?
- Is the node in top-level code, module body code, or function code?
- Is the node trusted user-authored source, quoted code, generated code, or below an opaque macro boundary?

It must not execute top-level code, module-body code, module callbacks, or
macro code. It must not expand user macros. It must not track compiler-only
state such as module attributes, `super`, overridable definitions,
delegations, typespec tables, or Elixir's internal compiler ETS tables.

## Recommendation

**Go for v1.14 first implementation, with narrow scope.**

Implement `Mut.EnvWalker` as a host-side source pass that runs after the
tracer oracle exists. It should classify source nodes and produce
`Mut.EnvSnapshot` records. The first mutator using it should be string body
literals only. Existing dispatch-shaped mutators must continue to use the
tracer oracle as the source of truth.

No stable-id migration is required if the first implementation preserves the
existing stable-id input contract and does not rewrite the current dispatch
candidate walker.

## Current Mutalisk Baseline

Mutalisk currently has `Mut.AstWalk` as a syntactic walker:

| Function | Current role | Limitation M39 addresses |
|---|---|---|
| `dispatch_candidates/2` | Finds dispatch-shaped call/operator AST nodes for tracer matching. | Does not classify arbitrary non-dispatch literals/patterns. |
| `guard_candidates/2` | Finds guard expressions syntactically under `when`. | Does not give a general env snapshot for every candidate. |
| `attribute_candidates/2` | Finds direct literal module attribute values. | Does not distinguish broader module-body compile-time shapes. |
| `body_literal_candidates/1` | M23 integer/boolean body literals via `literal_encoder`. | Uses path heuristics for body vs guard/pattern/quote and does not understand module/function scope deeply. |

v1.14 acceptance forbids any change to `Mut.AstWalk.dispatch_candidates/2`,
`guard_candidates/2`, `attribute_candidates/2`, or `body_literal_candidates/1`.
`Mut.EnvWalker` is added as a fifth candidate source consumed only by the new
`Mut.Mutator.StringLiteral`. Migration of existing walkers behind `EnvWalker` is
a v1.15+ milestone with its own stable-id byte-identity gate.

## Reference Findings

### `:elixir_expand`

`~/elixir/lib/elixir/src/elixir_expand.erl` is the compiler's expansion
implementation. It is useful as semantic reference, not as a dependency.

Relevant behavior observed:

- `=` expands the right side in current context, then expands the left side in
  match context.
- Function heads expand arguments in match context and guards in guard context.
- `case`, `fn`, `receive`, `try`, `with`, and `for` route clause heads through
  match context and guard expressions through guard context.
- `quote` builds quoted AST and handles `unquote` through compiler quote logic.
- Local and remote calls invoke dispatch and macro expansion machinery.
- `defmodule` ultimately enters `elixir_module:compile/6`, which creates ETS
  tables, evaluates module forms, compiles definitions, and invokes callbacks.
- Function definitions are stored through `elixir_def`, backed by module ETS
  tables and compiler state.
- `Kernel.if/2` is a macro that emits a `case` with
  `optimize_boolean: true` and a falsy branch guard. `Kernel.unless/2` emits an
  `if` with swapped branches. Calling the macro is forbidden for mutalisk; if
  trusted, they need dedicated syntactic traversal.
- `if`/`unless` are not valid guard constructs because their expansion contains
  `case`. Mutalisk should not treat them as guard-safe just because the source
  spelling looks like a Kernel macro.

This confirms why mutalisk must not call `:elixir_expand` directly. It is not
a pure classifier. It is the compiler.

### `elixir_rewrite`

`~/elixir/lib/elixir/src/elixir_rewrite.erl` rewrites selected Elixir calls to
Erlang calls after dispatch resolution. Examples include Kernel operators,
`Kernel.elem/2` to `:erlang.element/2` with index adjustment,
`Map.has_key?/2` to `:maps.is_key/2`, and guard validation against Erlang guard
BIFs.

The env walker should not model these rewrites. Rewrite rules do not establish
source context; they alter the compiled dispatch target. Existing dispatch
mutators already rely on the tracer oracle for the compiler-resolved target.
Future literal mutators mutate source and then let fallback compilation apply
the same rewrite rules naturally. Guard legality derived from rewrite rules
belongs in guard mutator applicability checks, not in the env walker.

### ElixirSense Compiler

`~/elixir_sense/lib/elixir_sense/core/compiler.ex` is the closest reference
for a tool-side traversal. It mirrors many `:elixir_expand` transitions and
uses public `Macro.Env` APIs through `ElixirSense.Core.Normalized.Macro.Env`.

Useful patterns to copy conceptually:

- The traversal records an environment before expanding metadata-bearing nodes.
- `defmodule` creates a new module environment and walks the body.
- `def`, `defp`, `defmacro`, `defmacrop`, `defguard`, and `defguardp` decompose
  the head into args, guards, and body.
- Clause helpers centralize match and guard handling for `case`, `fn`, `with`,
  `receive`, and `try`.
- Public `Macro.Env.define_alias/4`, `define_require/4`, `define_import/4`,
  `expand_alias/4`, `expand_import/5`, and `expand_require/6` are used instead
  of direct compiler ETS access. Mutalisk should use only the strict subset
  listed below.

Where mutalisk must be stricter:

- ElixirSense expands macros through callbacks for richer IDE metadata.
  Mutalisk must not do this.
- ElixirSense handles module callbacks such as `@before_compile` best-effort.
  Mutalisk must not invoke or simulate them.
- ElixirSense tracks definitions, docs, attributes, types, protocols, vars,
  behaviours, and calls. Mutalisk should not track these unless needed for
  mutation context.
- ElixirSense has compatibility shims for old Elixir versions. Mutalisk already
  requires Elixir `>= 1.19.0`, so no shim layer is needed for M39 APIs.

## Data Model

Add a small snapshot struct. Names are draft but the fields should remain
serializable and explicit.

```elixir
defmodule Mut.EnvSnapshot do
  @type context :: nil | :match | :guard
  @type scope ::
          :top_level
          | :module_body
          | :attr_value
          | :function_head
          | :function_body
          | :macro_definition
          | :quote
          | :opaque_macro

  @type trust_level ::
          :trusted
          | :opaque
          | :untrusted_descendant
          | :quoted
          | :generated

  defstruct [
    :file,
    :line,
    :column,
    :source_span,
    :ast_path,
    :ast_path_hash,
    :module,
    :function,
    :context,
    :scope,
    :trust_level,
    aliases: %{},
    imports: %{},
    requires: MapSet.new()
  ]
end
```

`scope` is the single source of truth for top-level, module-body, function-head,
function-body, attribute, quote, macro-definition, and opaque regions. If a
mutator wants a coarser region, derive it from `scope`: `:top_level` maps to top
level; `:module_body` and `:attr_value` map to module body; `:function_head`,
`:function_body`, and `:macro_definition` map to function code. For example, a
literal in a default argument has `scope: :function_head` and `context: nil`, but
it is not a normal function-body literal.

`aliases`, `imports`, and `requires` are mutalisk-owned normalized maps, not raw
`%Macro.Env{}` private fields. Persist `requires` as a sorted list if the oracle
is serialized.

Add `Mut.EnvOracle` as an index:

```elixir
%Mut.EnvOracle{
  by_span: %{{file, start_byte, end_byte} => [Mut.EnvSnapshot.t()]},
  by_ast_path: %{{file, ast_path_hash} => Mut.EnvSnapshot.t()},
  diagnostics: [Mut.EnvWalker.diagnostic()]
}
```

Define diagnostics explicitly:

```elixir
@type diagnostic :: %{
        file: Path.t(),
        line: pos_integer(),
        reason:
          :ambiguous_form
          | :unresolvable_module
          | :opaque_descendant_with_literals
          | :missing_source_span,
        detail: String.t()
      }
```

Define the macro index consumed by the walker:

```elixir
@type tracer_macro_index :: %{
        {
          file :: String.t(),
          line :: pos_integer(),
          column :: pos_integer() | nil,
          name :: atom(),
          arity :: non_neg_integer()
        } => %{
          kind: :local_macro | :remote_macro | :imported_macro,
          resolved_module: module() | nil,
          resolved_name: atom(),
          resolved_arity: non_neg_integer()
        }
      }
```

Build it once from existing `Mut.Oracle.DispatchSite` records filtered to
`*_macro` dispatch kinds. The walker queries it on every call node that is not a
known special form.

The walker should store snapshots for metadata-bearing AST nodes and
literal-encoder wrapper nodes that may become mutation targets. It does not
need to persist a snapshot for every list cell.

## Parser Mode

Use the same parser options as the existing source pass plus
`literal_encoder` when discovering literal candidates:

```elixir
Code.string_to_quoted(source,
  file: file,
  columns: true,
  token_metadata: true,
  emit_warnings: false,
  literal_encoder: fn literal, meta -> {:ok, {:__block__, meta, [literal]}} end
)
```

The literal-encoded AST is the right input for env-walker literal discovery
because bare strings, atoms, numbers, lists, and booleans otherwise lose parser
metadata. The normal AST should remain the input for existing dispatch matching
until a separate migration proves identical stable IDs.

`EnvSnapshot` keys must include source byte spans whenever possible. If a node
has no reliable span, mutators that need stable reporting should skip it with
`:missing_source_span` rather than falling back to a lossy whole-file render.

## Context Discrimination

The walker consumes the AST returned by `Code.string_to_quoted/2`. It never sees
post-`Macro.expand` forms. Syntactic-form recognition (`if`, `unless`, `case`,
`cond`, `with`, `for`, `try`, `fn`, `receive`, `quote`, `=`, `when`, `^`, `&`,
and function-definition forms) is therefore exhaustive for those forms.

This is a correctness property, not only a purity constraint. Calling
`Macro.expand_once/2` would replace source forms such as `if` with generated
forms such as `case`, losing source spans, source AST paths, and the user's
spelling that stable IDs and reports must preserve.

The walker is a recursive descent over source AST. Each recursive call carries:

- current `%Macro.Env{}` for public fields `file`, `line`, `module`,
  `function`, and `context`;
- a mutalisk-owned env state containing `scope`, `trust_level`, `aliases`,
  `imports`, and `requires`;
- the source file, source text, line offsets, AST path, and tracer macro index.

Minimal main loop sketch:

```elixir
def walk(node, env, state) do
  snapshot(node, env, state)

  case node do
    {:defmodule, meta, [module_ast, body]} ->
      module = resolve_module(module_ast, env, state)
      walk_module_body(body, %{env | module: module, function: nil, context: nil}, state)

    {kind, meta, [head, body]} when kind in [:def, :defp, :defmacro, :defmacrop] ->
      walk_def(kind, meta, head, body, env, state)

    {kind, meta, [head, body]} when kind in [:defguard, :defguardp] ->
      walk_defguard(kind, meta, head, body, env, state)

    {:fn, meta, clauses} ->
      walk_clauses(clauses, env, %{state | scope: :function_body})

    {:case, meta, [expr, opts]} ->
      walk(expr, env, state)
      walk_clauses(Keyword.get(opts, :do, []), env, state)

    {:with, meta, args} ->
      walk_with(args, env, state)

    {:try, meta, opts} ->
      walk_try(opts, env, state)

    {:quote, meta, _args} ->
      snapshot(node, env, %{state | scope: :quote, trust_level: :quoted})

    {name, meta, args} when special_leaf?(name, args) ->
      snapshot(node, env, state)

    {name, meta, args} when known_special_form?(name, args) ->
      walk_special_form(name, meta, args, env, state)

    {name, meta, args} when call?(name, args) ->
      case macro_index_lookup(state.macro_index, node) do
        nil -> walk_call_args(args, env, state)
        macro -> mark_opaque_boundary(node, macro, env, state)
      end
  end
end
```

The sketch is intentionally incomplete for expression details. The invariant is
that context transitions are explicit at each source form; generic recursive
descent is used only after the form is known not to change context.

### Top Level

Initial state:

```elixir
%{
  module: nil,
  function: nil,
  context: nil,
  scope: :top_level,
  trust_level: :trusted
}
```

Top-level expressions are compile-time code. The walker may classify them but
mutators should skip them by default. Direct `defmodule` forms are known-safe
entry points. Other top-level calls are opaque compile-time code unless a
future SPEC explicitly supports scripts.

### Module Body

For `defmodule Module do ... end`, resolve `Module` syntactically from the
alias AST and current module. Enter:

```elixir
%{env | module: Module, function: nil, context: nil}
%{state | scope: :module_body}
```

Trusted direct module-body forms:

- `alias`, `require`, and `import` as environment declarations;
- direct module attributes, classified as `scope: :attr_value` for their
  values;
- `def`, `defp`, `defmacro`, `defmacrop`, `defguard`, and `defguardp`;
- nested direct `defmodule`.

Opaque module-body forms:

- `use`;
- user DSL calls such as `schema do ... end`, `plug ...`, `field ...`, or
  any other non-declaration call;
- `if`, `case`, `cond`, `with`, or other control flow that appears in module
  body and may conditionally create definitions;
- module callbacks registered through attributes, such as `@before_compile`,
  `@after_compile`, `@after_verify`, `@on_definition`, and `@on_load`.

This is deliberately stricter than ElixirSense. Mutalisk does not evaluate
module-body control flow to decide which definitions exist. Existing tracer
events remain the source of truth for definitions and dispatch-shaped code that
the real compiler actually compiled.

### Function Heads And Bodies

For `def` and `defp`:

- Decompose the raw head syntactically, including a small `when` splitter.
- Function head arguments are `scope: :function_head`, `context: :match`.
- Default arguments have AST shape `{:\\, _, [arg, default]}`. The `arg` side
  walks with `scope: :function_head`, `context: :match`; the `default` side
  walks with `scope: :function_head`, `context: nil`. Defaults are evaluated at
  call site in caller context, so `context: nil` is correct. They should route
  to fallback or skip, not to first-pass body literal mutators.
- Guard expressions are `scope: :function_head`, `context: :guard`.
- Function bodies are `scope: :function_body`, `context: nil`.

For `defmacro` and `defmacrop`, classify the head the same way but mark the body
as `scope: :macro_definition`. First-pass mutators must skip macro definitions.
This avoids mutating code whose primary effect is compile-time AST generation.

For `defguard` and `defguardp`, classify the head with `scope: :function_head`,
`context: :match`. Classify the body as `scope: :function_body`,
`context: :guard`. Defguard bodies are evaluated as guard expressions wherever
they are inlined. Treating them as guard context naturally excludes them from
string-literal mutators and naturally includes them under guard-mutator surface
when those land.

Anonymous functions (`fn`) do not change `scope` away from `:function_body` and
do not change `enclosing_function`. The walker pushes a new lexical scope for
clause heads (`context: :match`) and clause bodies (`context: nil`), but
`scope: :function_body` and `function: surrounding_def` remain. The same applies
to `case`, `for`, and `with` clause bodies inside a function. Capture syntax
(`&...`, including `& &1`) also defines an anonymous function; its body remains
in the surrounding function-body scope for mutation purposes.

### Match Context

Enter match context for:

- left side of `=`;
- function and anonymous-function clause heads;
- `case`, `fn`, `receive`, `with ... <-`, `for ... <-`, `try/rescue`,
  `try/catch`, and `try/else` clause heads;
- `with ... else` clauses, identical to `case` clauses: head in match context,
  body in normal context;
- `try rescue` clauses, including `rescue ExceptionPattern -> ...` and
  `rescue [E1, E2] -> ...`; the rescue head is a pattern in match context and
  the body is normal context;
- map/list/tuple destructuring descendants when the parent is already in
  match context.

The pin operator is special. The `^` node itself is part of match context, but
the pinned expression is evaluated outside match context, following
`:elixir_expand` behavior. Record the child as `context: nil` plus a future
`pattern_role: :pinned` if variable mutators need it.

### Guard Context

Enter guard context for:

- `when` parts in function heads;
- `when` parts in `case`, `fn`, `receive`, `with else`, `try/rescue`,
  `try/catch`, and `try/else` clauses;
- chained `when` guards, preserving `context: :guard` for each guard branch.

Guard literals and guard dispatches route through fallback unless a later guard
schema SPEC changes that. The walker's job is classification, not engine
selection.

### Normal Body Context

Normal function-body descendants keep `context: nil`. This is the only context
where first-pass string body literal mutators should run:

```elixir
snapshot.scope == :function_body and
snapshot.context == nil and
snapshot.trust_level == :trusted
```

### `if` And `unless`

`if` and `unless` are trusted only as **known Kernel control-flow macros in
function-body expression context**. They are not trusted by generic macro
expansion.

Recognition rules:

- The call must be syntactically shaped as `if(condition, clauses)` or
  `unless(condition, clauses)`.
- The tracer oracle must have a matching `:imported_macro` / `:remote_macro`
  site resolving to `Kernel.if/2` or `Kernel.unless/2`. Without tracer proof,
  classify it as an opaque macro boundary.
- The current snapshot must be `scope: :function_body` and `context: nil`. In
  module body it remains opaque compile-time code. In guard or match context it
  is unsupported/opaque.

Traversal rules:

- The condition is walked in normal expression context (`context: nil`). This
  matches the source-level view; any variables introduced by matches in the
  condition are a future variable-mutator concern.
- `do` and `else` blocks are walked in normal function-body context. For future
  variable mutators, treat each branch as a non-leaking variable scope, matching
  the macro's `case` semantics.
- Do not synthesize or walk the generated `case`, falsy pattern, or `in/2`
  guard from Kernel's macro implementation.
- Do not model `optimize_boolean: true`. It changes the generated `case` when
  the compiler proves the condition returns boolean; it does not change source
  mutation context.
- `unless` uses the same classification as `if`; the semantic branch swap does
  not affect context. Stable IDs and spans remain attached to the original
  source branch expressions, not to a synthetic `if` expansion.

### Quote And Unquote

`quote` bodies are `trust_level: :quoted`, `scope: :quote`, and skipped by
default. `unquote` and `unquote_splicing` inside quoted code are also skipped
in the first implementation. The walker may record diagnostics for literals
inside quoted code, but it must not generate mutants there.

This is stricter than the compiler, which evaluates quote options and builds
quoted forms. Mutalisk treats quote as a boundary because source inside a quote
is usually code-as-data for a macro or DSL.

### Compile-Time Special Leaves

`__ENV__`, `__CALLER__`, `__STACKTRACE__`, `__DIR__`, and `__MODULE__` are
special forms returning compile-time values. The walker records them as leaves,
does not descend, and never mutates them.

### Generated Code

Any node with `generated: true` metadata is `trust_level: :generated` and
skipped. If metadata contains a `:file` that differs from the source file being
walked, classify it as generated/external and skip. This mirrors the v1 tracer
generated-code filter.

## User Macro Opacity Policy

The walker does not expand user macros. It uses syntax and the existing tracer
oracle to identify macro boundaries.

Known-safe forms are handled by dedicated walker clauses:

| Form class | Examples | Policy |
|---|---|---|
| Declarations | `defmodule`, `def`, `defp`, `alias`, `require`, `import`, `@` | Classify known subexpressions. |
| Function control flow | `case`, `cond`, `with`, `for`, `receive`, `try`, `fn` | Classify patterns, guards, and bodies. |
| Kernel control-flow macros | `if`, `unless` | Dedicated syntactic traversal in function bodies only; requires tracer proof of `Kernel.if/2` or `Kernel.unless/2`. |
| Operators | `=`, `when`, `and`, `or`, `&&`, `||`, comparisons, arithmetic | Descend according to context; dispatch mutators still use tracer. |
| Quote | `quote`, `unquote`, `unquote_splicing` | Boundary; skip by default. |

Opaque boundaries:

- any tracer dispatch site with kind `:local_macro`, `:remote_macro`, or
  `:imported_macro` unless it is in the known-safe form table;
- any `use` call;
- any module-body call that is not a direct known declaration;
- any call with a `do` block that is not a known-safe form and has no tracer
  proof that it is a function;
- any dynamic `defmodule` target that cannot be resolved syntactically.

Boundary classification:

- The macro call node gets `trust_level: :opaque`, `scope: :opaque_macro`.
- Descendants, if walked for diagnostics, get
  `trust_level: :untrusted_descendant`.
- Mutators must reject `:opaque` and `:untrusted_descendant` by default.

No-expansion property by inspection:

- Do not call `Macro.expand/2` or `Macro.expand_once/2`.
- Do not call `Code.eval_string/3`, `Code.eval_quoted/3`,
  `Code.compile_string/2`, `Code.compile_file/2`, or
  `Kernel.ParallelCompiler`.
- Do not call `:elixir_expand`, `:elixir_module`, `:elixir_def`, or
  `:elixir_dispatch` directly.
- Do not call the expander callbacks returned by `Macro.Env.expand_import/5`
  or `Macro.Env.expand_require/6`. Prefer not to call those APIs at all in the
  first implementation.
- Do not invoke module callbacks or `__using__/1`.

## Public API Surface

Required public APIs:

| API | Use | Stability note |
|---|---|---|
| `Code.string_to_quoted/2` | Parse source with columns, token metadata, and literal encoder. | Public and already used by mutalisk. |
| `Code.env_for_eval/1` | Create a base `%Macro.Env{}` with file/line/default Kernel imports. | Public since 1.14. |
| `Macro.Env.prune_compile_info/1` | Ensure no lexical tracker/tracers leak into stored or reused envs. | Public since 1.14. |
| `Macro.Env.to_match/1` | Enter match context. | Public. |
| `Macro.Env.to_guard/1` | Enter guard context. | Public since 1.17. |
| `Macro.Env.in_match?/1` | Assertions/tests for context transitions. | Public. |
| `Macro.Env.in_guard?/1` | Assertions/tests for context transitions. | Public. |
| `Macro.Env.define_alias/4` | Update env for syntactic aliases with `trace: false`. | Public since 1.17. Current floor is 1.19. |
| `Macro.Env.define_require/4` | Update env for syntactic requires with `trace: false`. | Public since 1.17. |
| `Macro.Env.expand_alias/4` | Resolve alias AST heads with `trace: false`. | Public since 1.17. Does not execute user macros. |
| `Macro.traverse/4` or explicit recursion | AST traversal. | Public. Explicit recursion is preferred for context-sensitive forms. |

APIs intentionally not used:

| API | Reason |
|---|---|
| `Macro.expand/2`, `Macro.expand_once/2` | They expand macros. |
| `Macro.Env.define_import/4` | It enumerates imported functions/macros through module info callbacks. The first implementation records imports syntactically in mutalisk state instead. |
| `Macro.Env.expand_import/5`, `Macro.Env.expand_require/6` | They return macro expander callbacks. Calling them creates an attractive footgun. |
| `Macro.Env.fetch_alias/2`, `fetch_macro_alias/2` | `@doc false`; avoid. |
| Direct reads of `env.aliases`, `env.functions`, `env.macros`, `env.requires`, `env.macro_aliases`, `env.versioned_vars`, `env.lexical_tracker`, `env.tracers` | Documented private fields in `Macro.Env`. Mutalisk keeps its own serializable alias/import/require maps instead. |
| `:elixir_env.new/0` | Private compiler API; use `Code.env_for_eval/1`. |

There are no required public-but-undocumented APIs in this design. No Elixir
floor bump is needed beyond the current `>= 1.19.0` requirement.

## Attribute Policy

The walker classifies module attributes but does not track or expand them.

Rules:

- Direct `@name value` in module body records `scope: :attr_value` for the
  value.
- Reserved compiler/documentation/typespec attributes are skipped for mutation:
  `@moduledoc`, `@doc`, `@typedoc`, `@spec`, `@type`, `@typep`, `@opaque`,
  `@callback`, `@macrocallback`, `@behaviour`, `@impl`, `@derive`,
  `@before_compile`, `@after_compile`, `@after_verify`, `@on_definition`,
  `@on_load`, `@compile`, and related compiler attributes.
- Non-reserved literal values may be fallback candidates if an attribute
  mutator is enabled.
- Attribute reads such as `@limit` inside functions are compile-time reads;
  the walker does not resolve their values. They are not body-literal targets.
- No attribute accumulation, persistence, deletion, or callback invocation is
  modeled.

## Explicit Non-Goals

The env walker does not track:

- `super` resolution;
- overridable definitions;
- `defdelegate` targets;
- local/private macro definitions for later expansion;
- typespec or callback tables;
- behaviour optional callbacks;
- protocol consolidation or implementation metadata;
- compiler ETS tables;
- lexical tracker or dependency tracing events;
- generated functions emitted by DSLs.

These are ElixirSense/compiler features, not mutation-context requirements.

## Stable-ID Strategy

No stable-id migration is required.

Policy:

- Existing dispatch-shaped mutants keep the current stable-id input:
  `relative_file_path`, `start_byte`, `end_byte`, `mutator_name`,
  `original_dispatch`, and mutation discriminator.
- `EnvSnapshot` fields are not added to stable-id input.
- Synthetic expansion nodes, including the `case` emitted by `Kernel.if/2`, are
  never used for stable-id spans or AST paths. IDs attach to source nodes only.
- Existing integer and boolean body-literal mutators keep their current
  `original_dispatch` strings (`@integer_literal`, `@boolean_literal`) and
  mutation metadata if migrated from `Mut.AstWalk.body_literal_candidates/1` to
  `Mut.EnvWalker`.
- `ast_path_hash` is currently a stable-id fallback only when byte spans are
  missing (`lib/mut/stable_id.ex:49-52`). Since M23 literals always have bytes,
  a future path-scheme migration is safe in principle but must still be
  validated empirically on demo_app before landing.
- New literal mutators use deterministic source spans and mutator-specific
  discriminators. Example original-dispatch strings: `@string_literal`,
  `@float_literal`, `@atom_literal`, `@list_literal`, `@map_literal`,
  `@tuple_literal`.
- Nodes without precise source spans are skipped rather than assigned unstable
  IDs.

Acceptance for the implementation milestone must include a byte-for-byte
stable-id comparison for all existing default mutators on demo_app,
plug_crypto, Decimal, and plug with env walker enabled vs disabled.

## Cold-Compile Cost Measurement

Measured with a throwaway `elixir -e` prototype on Elixir 1.19.5 / OTP 28.
The prototype parses `lib/**/*.ex` with `columns: true` and
`token_metadata: true`, then performs a recursive context walk for module,
function, match, guard, quote, generated, and opaque counters. No prototype
code was added to `lib/`.

| Target | Source tree | Files | Parse ms | Walk ms | Parse + walk ms | Existing oracle build ms | Over oracle build |
|---|---|---:|---:|---:|---:|---:|---:|
| demo_app | `test/fixtures/demo_app` | 8 | 3.406 | 0.012 | 3.418 | 5513 | 0.06% |
| Decimal | `~/claude_fun/elixir_oss/projects/decimal` | 4 | 6.047 | 0.392 | 6.439 | 3037 | 0.21% |
| plug | `~/claude_fun/elixir_oss/projects/plug` | 42 | 31.626 | 2.792 | 34.418 | 4798 | 0.72% |

Existing oracle build numbers are from committed benchmark reports:

- `bench/results/demo_app.static.c4.stryker.json`
- `bench/results/decimal.static.c4.stryker.json`
- `bench/results/plug.static.c4.stryker.json`

Conclusion: the walker is well below the hard constraint. Even if the
production walker is 10x slower than the prototype, it should not double
oracle-build wall on Decimal-class projects. Set the v1.14 gate at
`parse + walk <= 10% of oracle_build_ms` on Decimal and plug.

## Mutator Ordering

Recommended implementation order after the walker lands:

| Order | Mutator | Why here |
|---:|---|---|
| 1 | String body literals | Lowest context complexity, no atom-table risk, obvious first replacement (`non_empty -> ""`). Good user value. |
| 2 | Float body literals | Simple literal surface after integer support; finite-float rules can mirror integer rules conservatively. |
| 3 | Atom body literals | Needs atom-table policy. Do not create arbitrary atoms by default; use configured replacements or atoms already present in the project. |
| 4 | List/map/tuple body literals | Requires noisier equivalence rules and careful handling of structs/map shape. Start with emptying only. |
| 5 | Better attribute literal classification | Uses `scope: :attr_value`; all route through fallback. Avoid compile-shape claims until measured. |
| 6 | Pattern-position literals | Requires high confidence in `context: :match` and fallback routing. Start with literal constants only. |
| 7 | Variable mutators | Highest semantic/noise risk. Needs explicit variable binding model and pin policy; do not include in first env-walker implementation. |

Pattern mutators beyond literal constants, such as pin/unpin swaps or arity
changes, remain v2 design work and are not part of M39's implementation
recommendation.

## v1.14 Go/No-Go Gate

M39 recommends **go** if v1.14 is scoped as follows.

Production deliverables:

- `Mut.EnvSnapshot` and `Mut.EnvOracle` structs.
- `Mut.OpaquePolicy` with known-safe forms and macro-boundary classification.
- `Mut.EnvWalker` with explicit recursion for module, function, match, guard,
  quote, attribute, and opaque contexts.
- Orchestrator integration for one new mutator: string body literals, fallback
  routed.
- Metrics for skipped `:opaque`, `:untrusted_descendant`, `:quoted`, and
  `:generated` candidate nodes.

LOC estimate:

- `Mut.EnvSnapshot` / `Mut.EnvOracle`: ~120 production LOC.
- `Mut.OpaquePolicy`: ~120 production LOC.
- `Mut.EnvWalker`: ~550 production LOC.
- String literal mutator and orchestrator integration: ~180 production LOC.
- Tests and goldens: ~450 LOC.
- Total: ~970 production LOC and ~450 test LOC.

Acceptance criteria:

- `bin/verify` green.
- Existing dispatch-shaped mutant stable IDs byte-identical with env walker
  enabled vs disabled on demo_app, plug_crypto, Decimal, and plug.
- No v1.14 changes to `Mut.AstWalk.dispatch_candidates/2`,
  `guard_candidates/2`, `attribute_candidates/2`, or
  `body_literal_candidates/1`; `Mut.EnvWalker` is a fifth candidate source for
  `Mut.Mutator.StringLiteral` only.
- Existing M23 integer/boolean body-literal stable IDs preserved if migrated to
  env walker; otherwise M23 path remains unchanged.
- Cold parse+walk overhead is <= 10% of oracle-build wall on Decimal and plug.
- No calls in production code to `Macro.expand/2`, `Macro.expand_once/2`,
  `Code.eval_*`, `Code.compile_*`, `Kernel.ParallelCompiler`,
  `:elixir_expand`, `:elixir_module`, or `:elixir_def` from the env walker.
- String body literal candidates appear only when `scope: :function_body`,
  `context: nil`, and `trust_level: :trusted`.
- `defguard` and `defguardp` body literals are correctly classified as guard
  context and excluded from `StringLiteral` mutator surface.
- Opaque DSL descendants are skipped by default and reported by reason.
- Validation targets: demo_app, plug_crypto, Decimal, plug, and one macro-heavy
  target from the existing harness (`gettext` or `phoenix_html`).

No-go or pivot criteria:

- Any existing dispatch-shaped stable ID changes without an explicit migration
  milestone.
- Env walker parse+walk exceeds 10% of oracle-build wall on Decimal or plug.
- The implementation needs macro expansion to classify common body literals.
- Opaque-policy validation shows trusted mutants inside known DSL-generated
  internals.

If a pivot is needed, prefer walker-on-demand for files with enabled v2 mutators
over global walker execution. Do not weaken macro opacity to recover coverage.
