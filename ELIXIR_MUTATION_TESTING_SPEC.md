# Elixir Mutation Testing Library SPEC

## Status

Draft HLD/SPEC for a modern Elixir mutation testing library using source-level mutant schemata, ExUnit integration, and isolated sandbox execution.

## Goals

- Make mutation testing practical on real Elixir projects by avoiding one full project rebuild per mutant.
- Keep mutations source-meaningful and reportable against user-authored Elixir code.
- Integrate cleanly with ExUnit and Mix without patching Elixir or relying on in-process test-suite reset hacks.
- Provide deterministic, stable mutant IDs suitable for incremental analysis.
- Emit Stryker-compatible mutation-testing-elements JSON plus fast terminal feedback.

## Non-Goals

- No Elixir compiler fork in v1.
- No mutation of DSL-generated code in v1.
- No user macro expansion in the oracle.
- No BEAM bytecode mutation in v1.
- No in-process ExUnit mutation runner.

## Version Targets

- Elixir `>= 1.19.0` (see `mix.exs`; raised 1.17 → 1.18 at v1.7, then 1.18 → 1.19 in the v1.20+ line).
- OTP `>= 26`.

Rationale: modern parser metadata, reliable column metadata, good JIT behavior, and no backwards-compatibility burden for a new tool. The 1.18 floor was originally adopted at v1.7 for the persistent worker (M19), but **the persistent worker was removed in v1.15** (the single fresh-process-per-mutant model proved simpler and no slower on real targets — see README), so that rationale is now historical. The current `>= 1.19.0` floor is the v1.20+ baseline; the catalogue/engine work since then targets 1.19's parser and stdlib (e.g. `:json`). `--worker-type persistent` is rejected; `--worker-type mix` is accepted as a deprecated no-op.

## High-Level Architecture

The library has three execution phases.

1. Oracle build.
2. Schema instrumentation build.
3. Mutant execution.

The core design mirrors Stryker's separation of mutator generation, orchestration/injection, runtime mutant selection, and rollback/fallback handling.

## Phase 1: Oracle Build

Compile the project once without mutations, with a mutation tracer registered through `Code.put_compiler_option(:tracers, [Mut.Trace])`.

The tracer records dispatch-shaped source facts from compiler trace events:

- `{:remote_function, meta, module, name, arity}`
- `{:remote_macro, meta, module, name, arity}`
- `{:local_function, meta, name, arity}`
- `{:local_macro, meta, name, arity}`
- `{:imported_function, meta, module, name, arity}`
- `{:imported_macro, meta, module, name, arity}`
- `{:alias_reference, meta, module}`
- `{:defmodule, meta}`
- `{:on_module, bytecode, _}`

Each trace event is normalized into an oracle record:

```elixir
%Mut.Oracle.DispatchSite{
  file: Path.t(),
  line: pos_integer(),
  column: pos_integer() | nil,
  end_line: pos_integer() | nil,
  end_column: pos_integer() | nil,
  env_context: nil | :match | :guard,
  module: module() | nil,
  function: {atom(), arity()} | nil,
  dispatch_kind: :remote_function | :remote_macro | :local_function | :local_macro | :imported_function | :imported_macro,
  resolved_module: module() | nil,
  resolved_name: atom(),
  resolved_arity: non_neg_integer(),
  event_file: Path.t(),
  meta: keyword()
}
```

The oracle stores only normalized, serializable data. It must not persist raw `%Macro.Env{}` because it contains process-local/compiler-local structures. The tracer can use `%Macro.Env{}` while running, but persisted oracle data is explicit.

### Oracle Policy

- The compiler is the source of truth for dispatch context.
- v1 does not attempt to infer context for arbitrary AST nodes.
- v1 mutates only nodes that can be matched to oracle dispatch sites.
- User macros and DSLs are opaque unless their call site itself is a supported mutation target.
- DSL-emitted internals are skipped by explicit generated-code filtering and by refusing unmatched AST nodes.

### Generated-Code Filtering

The tracer must drop trace events that do not correspond to user-authored source in the file being compiled.

Drop an event when any condition is true:

- `Keyword.get(meta, :generated, false) == true`.
- `event_file != env.file`, where `event_file = Keyword.get(meta, :file, env.file)`.
- `Keyword.get(meta, :context)` is present and differs from `env.module`. On Elixir 1.20-rc this is the empirical marker for plain `quote` macro internals emitted by another module when `generated: true` is not present.
- The event has no usable `:line` metadata.

Dispatch module allowlists are enforced by mutators, not globally by the tracer. For example, arithmetic mutators only accept resolved `Kernel` or `:erlang` arithmetic operators, while a configured function-call mutator may accept project modules. Non-allowlisted dispatch sites remain in the oracle for diagnostics but produce skipped mutants with reason `:unsupported_dispatch`.

### Source-AST To Oracle Matching

The schema instrumenter must never mutate an AST node unless it can be matched to exactly one oracle dispatch site.

Primary match key:

```elixir
{
  relative_file,
  line,
  column,
  dispatch_kind,
  resolved_name,
  resolved_arity
}
```

The source AST walker computes dispatch-shaped candidate nodes and annotates each candidate with:

```elixir
%Mut.Oracle.AstCandidate{
  file: Path.t(),
  line: pos_integer(),
  column: pos_integer() | nil,
  syntactic_name: atom(),
  syntactic_arity: non_neg_integer(),
  source_span: Mut.SourceSpan.t() | nil,
  ast_path: [term()],
  ast_path_hash: binary(),
  node: Macro.t()
}
```

Matching algorithm:

1. Build an oracle index by primary match key.
2. Build an AST-candidate index by file, line, column, syntactic name, and arity.
3. Ask each enabled mutator whether an AST candidate and an oracle site are compatible, because some syntax maps to different resolved dispatch names after expansion.
4. If exactly one compatible pair exists, attach the oracle site to the AST candidate and record `ast_path_hash` in the mutation context.
5. If multiple compatible pairs remain, refine by source span and `ast_path_hash` only when the span makes the candidate unique.
6. If the match is still ambiguous, skip all ambiguous candidates and emit a diagnostic with reason `:ambiguous_oracle_match`.
7. If no compatible oracle site exists, skip the AST candidate with reason `:missing_oracle_site`.

Columnless trace events are allowed only when the remaining key resolves to exactly one AST candidate in the same file and line. Otherwise they are skipped. Silent best-effort mutation is forbidden.

## Phase 2: Schema Instrumentation Build

Parse original source files with metadata-rich parser options:

```elixir
Code.string_to_quoted!(source,
  file: file,
  columns: true,
  token_metadata: true
)
```

Walk the original source AST and consult the oracle. For each oracle-backed mutable node, mutators generate one or more alternatives.

Instrumentation emits mutant schemata at expression positions when legal:

```elixir
case active_mutant do
  0 -> original_expr
  123 -> mutated_expr_a
  124 -> mutated_expr_b
  _ -> original_expr
end
```

The active mutant value may be hoisted once per function body as an optimization:

```elixir
active_mutant = :persistent_term.get(Mut.Runtime.active_key(), 0)
```

Hoisting is not required. If hoisting is awkward for a function shape, the placer may inline `:persistent_term.get(Mut.Runtime.active_key(), 0)` directly in each generated `case`. Any generated variable must use `Macro.unique_var/2` or equivalent hygiene; hard-coded names such as `mut__` are forbidden. If a function has no schema mutants, no runtime selector is inserted.

### Runtime Selector

- Use `:persistent_term`, not environment variables or application config.
- Active mutant key: `Mut.Runtime.active_key/0`, defaulting to `{Mut.Runtime, :active_mutant}`.
- Original code path: mutant ID `0`.
- A worker VM runs exactly one active mutant at a time.
- Async ExUnit tests are safe because the mutant ID is process-independent and VM-global for the worker.

### Injection Rules

The schema engine may instrument only expression positions that preserve semantics for mutant `0` and compile without context-specific restrictions.

Allowed in v1:

- Function body expressions with `env_context == nil`.
- Dispatch-shaped operator/function-call nodes with supported mutators.
- Built-in control-flow macro call sites when the mutation is on a dispatch-shaped operand observed by the tracer.

Not schema-instrumented in v1:

- Guard expressions.
- Match/pattern contexts.
- Module body compile-time expressions.
- Module attribute values.
- User macro bodies and DSL-generated code.
- `quote` bodies and unquote-sensitive regions.

Unsupported schema contexts are routed to fallback or skipped according to category.

## Phase 3: Mutant Execution

Execution uses isolated worker BEAM VMs launched through ports. No in-process ExUnit reruns are allowed.

Each worker receives:

- Sandbox root.
- Active mutant ID.
- Test files to run.
- Timeout.

Worker flow for schema mutants:

1. Start from the schema-instrumented build sandbox.
2. Set `:persistent_term.put(Mut.Runtime.active_key(), mutant_id)` inside the worker VM before loading tests.
3. Run selected ExUnit tests with `mix test --no-compile --no-deps-check --no-archives-check`.
4. Stop on first failing selected test when feasible via `--max-failures 1`.
5. Classify result.

Workers must use `--no-compile` for schema mutants. The schema build is already compiled; allowing `mix test` to invoke the compiler would erase the core one-compile-many-runs performance property and can introduce nondeterministic build artifacts.

## Sandbox Model

Use copy-on-write sandboxing similar to Muex:

- Build artifacts are isolated from the user's normal `_build` tree.
- Oracle build path: `MIX_BUILD_PATH=_build/mut_oracle`.
- Schema build path: `MIX_BUILD_PATH=_build/mut_schema`.
- Worker sandboxes clone from the schema build path, not from the user's build path.
- Create a reusable sandbox pool sized to worker concurrency.
- Symlink stable project inputs where safe: `deps`, config, top-level files.
- Use APFS `cp -Rc` on macOS and `cp -R --reflink=auto` on Linux for build/source copies when possible.
- Each worker has an independent `_build/test` tree or copy-on-write view of the app being mutated.
- A worker must never mutate the user's real source tree.

## Fallback Engine

Fallback handles mutations that cannot be represented safely as runtime schemata.

v1 fallback categories:

- Guard mutations.
- Module attribute value mutations.
- Any compile-time-view mutation selected by an enabled mutator.

Fallback is not a full project rebuild. It runs per-mutant recompile on top of the already schema-instrumented build.

### Fallback Flow

1. Start from a worker sandbox containing the schema-instrumented build.
2. Patch the target source file in the sandbox with exactly one fallback mutant.
3. Determine compile-connected dependent source files from Mix's Elixir compiler manifest.
4. Recompile only the mutated source file plus compile-connected dependents.
5. Run selected tests with compile disabled.
6. Restore the patched source and BEAM outputs from the sandbox's baseline schema build.

Fallback performs its recompile as an explicit `Mut.Recompile` step before test execution. The subsequent test command must still pass `--no-compile --no-deps-check --no-archives-check`; otherwise `mix test` may invoke Mix's compile manager and turn fallback into an uncontrolled incremental project compile.

`Mut.Recompile` may use `Kernel.ParallelCompiler.compile_to_path/3` or Mix compiler internals, but it must compile only the planned source set into the worker sandbox's schema build path. It must not run full `mix compile` for fallback mutants.

### Fallback Patch Representation

Fallback patches are byte-range source edits, not whole-file AST reprints.

Patch generation rules:

- Compute the original node source span from parser metadata, token metadata, and source text.
- Render only the mutated sub-expression with `Macro.to_string/1` or the formatter for that isolated expression.
- Splice the rendered mutant into the sandbox source file at the original byte range.
- Persist a patch record containing original byte range, original snippet, mutated snippet, and line/column mapping for reports.

Patch record:

```elixir
%Mut.SourcePatch{
  file: Path.t(),
  start_byte: non_neg_integer(),
  end_byte: non_neg_integer(),
  start_line: pos_integer(),
  start_column: pos_integer() | nil,
  end_line: pos_integer() | nil,
  end_column: pos_integer() | nil,
  original: String.t(),
  replacement: String.t()
}
```

Whole-file AST render is forbidden for fallback because it loses comments, changes formatting, and degrades diff/diagnostic quality. If a node span cannot be computed precisely, the fallback mutant is skipped with reason `:missing_source_span`.

### Compile-Connected Dependents

Fallback recompile must account for modules whose compile-time view depends on the mutated module.

The dependency source is Mix's compile manifest:

```text
_build/mut_schema/<env>/lib/<app>/.mix/compile.elixir
```

Fallback reads the manifest from the schema-instrumented build path. The library should use public/internal-compatible manifest reading where available. The manifest exposes source/module records containing references such as compile, export, runtime, and external references.

Dependency policy:

- Runtime dependents are ignored.
- Compile dependents are recompiled.
- Struct/export dependents are recompiled when the mutation can affect exported compile-time shape.
- Transitive compile dependents are recompiled.
- For ordinary body and guard mutations, the dependent set is usually empty; replacing the target module BEAM is enough.

API sketch:

```elixir
Mut.Recompile.dependents(mutated_modules,
  manifest: manifest_path,
  dep_kinds: [:compile, :struct, :export]
) :: MapSet.t(Path.t())
```

Default dep kinds:

- Guard/body fallback: `[:compile]`, usually empty.
- Module attribute fallback: `[:compile, :struct, :export]` if the mutated file defines structs or exported compile-time values; otherwise `[:compile]`.

The implementation may start conservatively with `[:compile, :struct, :export]` for all fallback mutants and optimize later.

### Fallback Correctness Cases

- `Foo.bar/1` body mutation: callers do not recompile; replace `Foo.beam` only.
- `Foo` guard mutation: callers do not recompile; replace `Foo.beam` only unless compile-time call dependencies exist.
- `@max 100` used only inside `Foo`: recompile `Foo` only.
- `Bar` calls `Foo.max()` at compile time: recompile `Foo` and `Bar`.
- `defstruct` mutation in future scope: recompile modules with struct/export dependencies.

## Mutant Model

```elixir
%Mut.Mutant{
  id: non_neg_integer(),
  stable_id: String.t(),
  engine: :schema | :fallback,
  mutator: module(),
  mutator_name: String.t(),
  mutation_kind: atom(),
  stable_id_kind: String.t() | nil,
  original_dispatch: String.t(),
  ast_path_hash: String.t() | nil,
  start_byte: non_neg_integer() | nil,
  end_byte: non_neg_integer() | nil,
  file: Path.t(),
  line: pos_integer(),
  column: pos_integer() | nil,
  span: {pos_integer(), pos_integer() | nil, pos_integer() | nil, pos_integer() | nil},
  module: module() | nil,
  function: {atom(), arity()} | nil,
  original_ast: Macro.t(),
  mutated_ast: Macro.t(),
  source_patch: Mut.SourcePatch.t() | nil,
  original_source: String.t() | nil,
  mutated_source: String.t() | nil,
  description: String.t(),
  status: :pending | :killed | :survived | :timeout | :invalid | :skipped | :error,
  skip_reason: atom() | nil,
  covering_tests: [Path.t()] | nil,
  killing_test: Path.t() | nil,
  duration_ms: non_neg_integer() | nil,
  compile_error: term() | nil
}
```

### Stable IDs

Mutant IDs must be stable across runs.

Stable ID input:

```text
relative_file_path\0start_byte_offset\0end_byte_offset\0mutator_name\0original_dispatch\0mutation_discriminator
```

Hash with SHA-256 and encode/truncate to a 64-bit or 128-bit stable identifier. The runtime integer ID can be assigned per run from sorted stable IDs, but reports must include the stable ID.

`mutation_discriminator` is `mutation_kind` for mutators that emit at most one replacement per site/kind. Mutators that emit multiple replacements for the same site/kind must include a stable replacement discriminator derived from deterministic mutation metadata, such as `arithmetic_op:operator=:+,replacement=:-`.

Byte offsets are derived from line/column metadata and source text. If either byte offset is missing, substitute a deterministic fallback containing the AST path hash and normalized original snippet to avoid collisions.

## Mutator Behaviour

Mutation context passed to mutators:

```elixir
%Mut.Context{
  oracle_site: Mut.Oracle.DispatchSite.t() | nil,
  enclosing_function: {atom(), arity()} | nil,
  enclosing_module: module() | nil,
  file: Path.t(),
  source_span: Mut.SourceSpan.t() | nil,
  ast_path: [term()],
  ast_path_hash: binary(),
  env_context: nil | :match | :guard,
  engine: :schema | :fallback
}
```

```elixir
defmodule Mut.Mutator do
  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback targets() :: [:dispatch | :guard | :module_attribute]
  @callback applicable?(Macro.t(), Mut.Context.t()) :: boolean()
  @callback mutate(Macro.t(), Mut.Context.t()) :: [Mut.Mutation.t()]
  @callback equivalent?(Mut.Mutation.t()) :: boolean()
end
```

`applicable?/2` receives `Mut.Context`, which includes oracle context for dispatch-shaped nodes. Mutators decide legality using resolved dispatch, env context, module/function, source metadata, and target engine.

Guard-safe replacements are declared separately from body replacements. Guard mutators in v1 still execute through fallback compile, but generation should avoid known illegal guard outputs.

## v1 Mutator Set

Initial mutators should be small, stable, and PIT/Stryker-inspired.

Schema mutators:

- Arithmetic operator replacement for resolved Kernel/Erlang arithmetic operators.
- Comparison operator boundary replacement for resolved comparison operators.
- Comparison negation for resolved comparison operators.
- Boolean operator replacement for `and`/`or` and `&&`/`||` when oracle confirms dispatch/context.
- Unary not removal/insertion when dispatch-shaped and legal.
- Function call deletion for selected side-effect-free or configured calls only; disabled by default until false-positive profile is understood.

Fallback mutators:

- Guard comparison boundary replacement.
- Guard comparison negation.
- Guard type-test swaps where replacements are guard-safe and semantically plausible.
- Module attribute literal replacement for numeric/string/boolean literals, if enabled.

Skipped in v1:

- Literal mutations outside module attributes.
- Pattern mutations.
- Variable mutations.
- User macro body mutations.
- DSL-generated code mutations.
- Return-value replacement mutations, unless a later SPEC pins concrete variants and equivalent-mutant rules.

## Orchestration

The instrumenter should follow Stryker-like roles.

Components:

- `Mut.Oracle`: stores dispatch sites and compile metadata.
- `Mut.Mutator.*`: generates mutation alternatives.
- `Mut.Orchestrator`: walks source AST, consults oracle, routes to schema/fallback/skip.
- `Mut.SchemaPlacer`: injects runtime `case` gates and hoisted active-mutant reads.
- `Mut.FallbackPlanner`: creates per-mutant source patches and dependent recompile plans.
- `Mut.CompileRollback`: compiles instrumented files and removes invalid schema mutants when needed.
- `Mut.Runner`: schedules mutants across sandboxes.
- `Mut.Reporter`: terminal and JSON output.

## Compile-Error Rollback

Schema instrumentation can introduce compile errors when a mutator or placer mishandles a context.

Policy:

- Compile instrumented project once.
- If compilation fails, identify candidate mutant IDs from AST metadata near the diagnostic location.
- Remove those mutants and retry up to a per-file budget.
- Mark removed mutants as `:invalid` with compile diagnostics.
- Do not discard all mutants in a file unless rollback budget is exhausted.

Per-file default rollback budgets:

- `max_rollback_iterations: 3`, meaning compile attempts after the initial failed schema compile.
- `max_invalid_mutants_per_file: max(10, ceil(file_mutants * 0.02))`, meaning the maximum number of mutants the rollback process may remove from one file before the whole file is marked rollback-exhausted.

Injected nodes should carry metadata such as:

```elixir
[mut_schema?: true, mut_ids: [123, 124], generated: true]
```

## Test Selection

v1 static dependency selection:

- Parse test files and map module references to test files.
- Include tests with aliases, imports, requires, `use Mod`, `@behaviour Mod`, direct calls, remote captures such as `&Mod.fun/N`, and `apply(Mod, fun, args)` when `Mod` is a literal module alias.
- If a test uses dynamic module dispatch such as `apply(module_var, fun, args)` or `Module.concat(...)`, fall back to all tests unless a more precise configured mapping exists.
- Include convention-based tests such as `FooTest` for `Foo`.
- Fall back to all test files when no dependency is known.

v1.5 coverage selection:

- Baseline test run records line/function coverage.
- Each mutant maps to tests covering its source line/function.
- Order selected tests by baseline runtime and convention match.

v2 incremental selection:

- Persist mutant result history.
- Reuse killed/survived/timeout results when source and covering tests are unchanged.
- Prioritize last killing test for previously killed mutants.

## Result Classification

- `:killed`: selected test fails with active mutant.
- `:survived`: all selected tests pass.
- `:timeout`: test execution exceeds mutant timeout.
- `:invalid`: mutant fails to compile or cannot be loaded.
- `:skipped`: unsupported mutation target or configured exclusion.
- `:error`: infrastructure failure such as worker VM startup failure, sandbox corruption, OOM, or port crash unrelated to mutant compilation.
- `:no_coverage`: no selected tests cover the mutant once coverage selection exists.

Infrastructure errors are retried once in a fresh sandbox. If the retry also fails, the mutant is marked `:error` and excluded from the mutation score denominator by default. Invalid mutants are also excluded from the score denominator because they do not measure test quality.

Timeout formula:

```text
timeout = max(configured_min_timeout, baseline_selected_tests_time * timeout_factor + timeout_const)
```

Defaults:

- `timeout_factor: 2.0`
- `timeout_const: 1000ms`
- `min_timeout: 5000ms`

## Reporting

Required v1 reporters:

- Terminal reporter optimized for local development.
- Stryker mutation-testing-elements JSON reporter.

Terminal output should show:

- Mutation score.
- Counts by status.
- Surviving mutants with file:line, mutator, description, and compact diff.
- Skipped unsupported categories grouped by reason.
- Fallback time percentage and fallback mutant percentage.

Stryker JSON should include stable IDs, source locations, replacement descriptions, and status mapping.

## Metrics To Capture From v1

The library must emit internal run metrics because they drive v2 decisions.

Required metrics:

- Total mutants.
- Schema mutants count and wall-clock.
- Fallback mutants count and wall-clock.
- Fallback percentage by count.
- Fallback percentage by wall-clock.
- Compile rollback count per file.
- Invalid mutants by mutator.
- Skipped mutants by reason.
- Test-selection fanout per mutant.

Wrapper-function guard schemata should only be designed if fallback wall-clock exceeds roughly `25%` on representative projects.

## Configuration

Example `mix.exs` config:

```elixir
config :mut,
  files: ["lib"],
  test_paths: ["test"],
  mutators: [:arithmetic, :comparison, :boolean, :guard_comparison],
  exclude: [~r/lib\/my_app_web\/router.ex/],
  fail_at: 80.0,
  concurrency: System.schedulers_online(),
  timeout_factor: 2.0,
  timeout_const: 1000,
  reporters: [:terminal, :stryker_json]
```

CLI examples:

```bash
mix mut
mix mut --files lib/my_app/foo.ex
mix mut --mutators arithmetic,comparison
mix mut --fail-at 85
mix mut --reporters terminal,stryker-json
mix mut --max-mutants 500
```

## Mix Task Flow

`mix mut` performs:

1. Ensure `MIX_ENV=test` unless explicitly overridden.
2. Compile baseline project with tracer oracle enabled under isolated `MIX_BUILD_PATH=_build/mut_oracle`.
3. Run baseline tests or selected baseline probes; abort if tests are not green.
4. Generate mutation plan from oracle and source AST.
5. Build schema-instrumented project under isolated `MIX_BUILD_PATH=_build/mut_schema`.
6. Execute schema mutants in sandbox workers.
7. Execute fallback mutants in sandbox workers with per-file incremental recompile.
8. Write reports.
9. Exit non-zero if score is below threshold or if configured to fail on invalid mutants.

## v2 Env Walker

v2 adds a lean Macro.Env-aware metadata builder for non-dispatch nodes.

Scope:

- Track `env.context`.
- Track `env.module` and `env.function`.
- Track alias/import/require state enough for dispatch classification.
- Track known special forms and Kernel macros.
- Track `quote`/`unquote` boundaries.
- Track pattern and guard positions.

Non-scope:

- No completion, hover, symbol, or code intelligence behavior.
- No user macro expansion.
- No DSL-generated code traversal.
- No full Elixir compiler emulation.

Policy for opaque macro calls:

- Record the call site.
- Do not descend with trusted context unless explicitly known safe.
- Mark descendants as `env_untrusted` if naive descent is useful for diagnostics.
- Mutators must refuse `env_untrusted` nodes by default.

v2 unlocks:

- Literal mutations in trusted body contexts.
- Pattern-shape mutations.
- More precise skipped diagnostics.

## Risks

- Trace metadata may be insufficient to match every source AST node unambiguously. Mitigation: robust source span keys and skip on ambiguity.
- Schema gates may alter evaluation order if inserted incorrectly. Mitigation: strict expression-position placer and golden tests for generated source.
- `:persistent_term` updates are global per worker VM. Mitigation: one mutant per VM run; never switch during a test run.
- Mix manifest format is internal. Mitigation: isolate manifest reading behind `Mut.MixManifest`, add version detection, and test against supported Elixir versions.
- DSL users may expect mutation inside generated functions. Mitigation: explicit skipped diagnostics and docs.

## Acceptance Criteria For v1

- Runs against a normal Mix project with no source modification in the user tree.
- Baseline compile/test failure aborts before mutation execution.
- Generates stable mutant IDs across repeated runs.
- Compiles schema-instrumented build once for schema mutants.
- Executes schema mutants by switching `:persistent_term` in isolated worker VMs.
- Executes guard and module-attribute fallback mutants via per-file incremental recompile in sandbox.
- Recompiles compile-connected dependent files for fallback based on Mix manifest.
- Emits terminal and Stryker JSON reports.
- Reports schema vs fallback count/time breakdown.
- Emits required v1 metrics, including fallback count/time, rollback count, invalid mutants by mutator, skipped mutants by reason, and test-selection fanout.
- Does not mutate user macro bodies or DSL-generated internals in v1.
