# Elixir Mutation Testing HLD: v1.5 and v2

## Context

v1 establishes the core architecture:

- Compiler-tracer oracle for dispatch-shaped source nodes.
- Source-AST schemata for body expressions.
- Per-mutant fallback compile for guards and compile-time/module-attribute cases.
- Port/sandbox isolation.
- Static test selection.
- Terminal and Stryker-compatible JSON reports.

v1.5 and v2 should build on that foundation without changing the core execution model. The main theme is precision: better test selection in v1.5, broader mutation surface in v2.

## v1.5 HLD: Coverage-Aware Test Selection

### Goal

Make v1 practical on medium-sized libraries by reducing per-mutant test work via coverage-informed selection. v1.5 does not improve kill rate (kill rate is a function of the user's test suite, not mutalisk); it reduces wall-clock by narrowing the test set per mutant.

The acceptance signal: Decimal-class projects either complete within a documented time budget OR coverage selection demonstrably reduces per-mutant test fanout by ≥10× and identifies the next bottleneck. v1's plug_crypto smoke validates the perf-neutral floor; v1.5's smoke validates the medium-project ceiling.

### Non-Goals

- Do not change schema/fallback execution mechanics.
- Do not change stable_id input shape — coverage data must NOT enter mutant identity.
- Do not mutate literals or patterns yet.
- Do not build the v2 env walker.
- Do not require compiler patches.
- Do not introduce persistent incremental history (in-run last-killer is fine; cross-run state is v2).
- Do not turn on parallel workers. v1.5 stays sequential. If coverage alone fails to move Decimal materially, scope reopens — but parallelism is not pre-committed.

### Core Idea

Add a baseline coverage oracle that maps source locations to tests that execute them:

```elixir
%Mut.CoverageOracle{
  by_line: %{Mut.SourceLocation.t() => [Mut.TestId.t()]},
  by_function: %{Mut.FunctionId.t() => [Mut.TestId.t()]},
  test_runtime_ms: %{Mut.TestId.t() => non_neg_integer()},
  fallback_static_tests: %{module() => [Mut.TestId.t()]}
}
```

Mutant execution uses this priority order:

1. Tests covering the exact mutant line.
2. Tests covering the enclosing function.
3. Static dependency-selected tests from v1.
4. All tests, only when no safer selection exists.

Selected tests are ordered by:

1. **In-run** last-killer for the same module if available (per-run only, in-memory; NO persistent history in v1.5).
2. Convention match such as `FooTest` for `Foo`.
3. Shortest baseline runtime first.
4. Stable path/name ordering for determinism.

### Selection Modes

v1.5 introduces a `--selection` CLI flag with three values:

- `static` (DEFAULT in first v1.5 release): v1 behavior unchanged. Coverage collection does not run. Acts as escape hatch and validates the non-regression path.
- `coverage_with_static_fallback`: collect coverage; if collection wall-clock exceeds 2× baseline test wall-clock, log a warning and fall back to `static` for the remainder of the run.
- `coverage`: collect coverage; if collection is pathological, fail visibly with a clear error. Does NOT silently downgrade — users in this mode want to know when coverage isn't working.

After v1.5 validates on real projects, a follow-up release flips the default to `coverage_with_static_fallback`. Shipping coverage-as-default in the first v1.5 release would mask edge-case bugs as silent fallbacks.

The mode is reported in every run's metrics and terminal output; users always know which selection ran.

### Coverage Collection Options

#### Option A: ExUnit Formatter + Source Probes

Instrument the schema build with lightweight coverage probes around source locations that already have mutants.

Example generated probe:

```elixir
Mut.Coverage.hit(test_ref(), mutant_site_id)
original_expr
```

Pros:

- Directly maps to mutation sites, not just lines.
- Avoids relying on `:cover` internals.
- Can collect per-test coverage even when multiple tests run in one VM.

Cons:

- Adds another instrumentation mode.
- Needs a reliable current-test identity.
- Async tests require process propagation if tested code runs in spawned processes.

#### Option B: `:cover` Per Test Module

Use Erlang `:cover` to collect line coverage while running one test module or one test file at a time.

Pros:

- Built-in tool.
- Lower implementation cost.
- Good enough for line-level selection.

Cons:

- Per-test-case coverage is expensive.
- Async test execution complicates attribution.
- `:cover` instrumentation can perturb performance and code loading.

#### Option C: Hybrid (deferred)

Start with per-test-file/module `:cover`, then introduce source probes for hot/ambiguous files. **Source probes are NOT in v1.5.** v1.5 ships Option B exclusively. Option C is a v2 path if v1.5 fanout proves insufficient.

### Recommendation

**v1.5 ships Option B exclusively.**

- Run coverage per test file or per test module, not per individual test case.
- Disable ExUnit `async: true` ONLY during coverage collection (set via `ExUnit.start(async: false)` in the coverage baseline run). Mutant runs preserve normal user config.
- Store line and function coverage in `Mut.CoverageOracle`.
- Use static dependency selection as a safety fallback in the `coverage_with_static_fallback` mode.
- "Exact line coverage" is concretely defined: `:cover.analyse(:coverage, :line)` reports the test executed the line where the mutant lives. Function-level fallback uses the enclosing function's line range.
- Coverage is recollected on every `mix mut` invocation. No caching, no disk-persisted oracle. v2 may add caching when stability is proven.

### Architecture Changes

New components:

- `Mut.Coverage.Runner`: runs baseline coverage collection in isolated build path under `_build/mut_coverage`.
- `Mut.Coverage.Parser`: normalizes `:cover.analyse/2` results into `CoverageOracle`.
- `Mut.TestSelection.Coverage`: extends the v1 `Mut.TestSelection` facade with coverage-based selection. Static remains as the underlying safety mechanism.
- `Mut.TestRuntime`: records baseline test runtime by test file/module for ordering.
- `Mut.LastKiller`: in-run, per-module last-killing-test cache (process-local; not persisted).

Existing components changed:

- `Mut.Worker` accepts an ordered list of test IDs from the selector rather than a raw test_files list.
- `Mut.Reporter.Terminal` and `Mut.Reporter.StrykerJson` include selection metrics and phase timings.
- `Mut.Metrics` gains structured phase timings and the selection metrics block.
- `Mix.Tasks.Mut` parses `--selection` and threads the mode through the pipeline.
- `Mut.Application` does NOT change — runtime gate behavior is unchanged.

No `Mut.History` module in v1.5. Persistent cross-run state is v2.

### Build Paths

v1.5 keeps v1 build isolation and adds a coverage build path:

```text
_build/mut_oracle
_build/mut_schema
_build/mut_coverage
```

The coverage build can be derived from the oracle or schema build, but it must not write into the user's normal `_build/test`.

### Data Model

```elixir
%Mut.TestId{
  kind: :file | :module | :case,
  file: Path.t(),
  module: module() | nil,
  name: String.t() | nil,
  line: pos_integer() | nil
}
```

v1.5 may use only `:file` and `:module` test IDs. `:case` is reserved for later.

```elixir
%Mut.Coverage.Site{
  file: Path.t(),
  line: pos_integer(),
  module: module() | nil,
  function: {atom(), arity()} | nil,
  mutant_ids: [Mut.Mutant.id()]
}
```

### Execution Flow

1. Build v1 oracle.
2. Generate v1 mutation plan.
3. Build coverage target from mutation sites.
4. Run baseline tests under coverage by test file/module.
5. Persist `CoverageOracle`.
6. Build schema-instrumented project.
7. For each mutant, ask `Mut.TestSelector.select(mutant, coverage_oracle, static_oracle)`.
8. Execute selected tests using v1 schema/fallback runners.
9. Report fanout and fallback-to-static rates.

### Metrics

v1.5 introduces two new metric blocks.

**Selection metrics** (per run):

- `coverage_match_distribution`: histogram of `[:exact_line, :enclosing_function, :static_fallback, :all_tests]` — counts per bucket across all mutants.
- `fallback_reason_distribution`: histogram of reasons coverage was NOT used (e.g., `:no_coverage_data, :coverage_pathological, :static_only_mode`).
- `selected_tests_avg`: average tests-per-mutant across the run.
- `selected_tests_median`: median tests-per-mutant.
- `coverage_collection_wall_ms`: wall-clock spent in baseline coverage run.
- `selection_mode`: the actual mode that ran (`:static`, `:coverage`, `:coverage_with_static_fallback`, `:downgraded_to_static`).

**Phase timing metrics** (per run, in `Mut.Metrics.Snapshot`):

- `oracle_build_ms`
- `baseline_tests_ms`
- `plan_generation_ms`
- `coverage_collection_ms` (zero for static mode)
- `schema_build_ms`
- `schema_workers_ms`
- `fallback_workers_ms`
- `report_writing_ms`
- `total_ms`

These appear in the Stryker JSON's `mutalisk` extension key and in the terminal summary. "Estimated wall-clock saved versus static" is NOT a metric — speculative comparisons mislead users.

### Risks

- Per-test-file coverage can overselect for large test files.
- `:cover` can conflict with hot code loading and schema builds.
- Tests that spawn processes may execute code outside the test process; line coverage still catches this, but attribution to a specific test file/module can blur if tests run concurrently.

### Acceptance Criteria

- All v1 `bin/verify` layers remain green.
- Coverage collection runs only in isolated `_build/mut_coverage`; the user's `_build/test` is never written.
- Test selection never silently drops to an empty set unless the mutant is explicitly marked `:no_coverage`.
- Static selection remains available as `--selection static` and is the safety fallback in `coverage_with_static_fallback` mode.
- `--selection coverage` does NOT silently downgrade — it fails or continues visibly.
- Demo_app fixture mutation outcomes remain stable (same kill/survived counts as v1).
- Stable IDs are byte-identical to v1 for the same plan; coverage data does not enter ID computation.
- plug_crypto smoke run still produces zero `:error`-status mutants.
- **Decimal acceptance**: completes within a documented budget (target: ≤30 minutes) OR coverage selection demonstrably reduces per-mutant test fanout by ≥10× and the v1.5 BENCHMARKS clearly identifies the next blocking bottleneck. Soft failure on this acceptance is permitted but must be honestly documented.
- Reports include phase timings AND selection metrics AND the active `selection_mode`.
- No new mutator surface is introduced.
- No persistent state is introduced (`tmp/`, in-memory only).

## v2 HLD: Lean Env Walker And Broader Mutators

### Goal

Expand mutation coverage beyond dispatch-shaped nodes while preserving source meaning and avoiding user macro expansion.

v2 adds a lean Macro.Env-aware source walker for trusted non-dispatch nodes:

- Literals in function bodies.
- Pattern shapes.
- Selected module-attribute literals with better context.
- More precise skip diagnostics around opaque macros and quote/unquote boundaries.

### Non-Goals

- No full compiler reimplementation.
- No code intelligence features from ElixirSense/ElixirLS.
- No user macro expansion.
- No mutation of DSL-generated internals.
- No compiler fork.

### Core Idea

Combine two oracles:

- v1 tracer oracle for dispatch-shaped nodes.
- v2 env walker oracle for source-AST nodes that do not produce compiler dispatch events.

The env walker tracks only mutation-relevant environment facts:

```elixir
%Mut.EnvSnapshot{
  file: Path.t(),
  module: module() | nil,
  function: {atom(), arity()} | nil,
  context: nil | :match | :guard,
  scope: :module_body | :function_body | :quote | :opaque_macro | :attr_value,
  trusted?: boolean(),
  aliases: map(),
  imports: map(),
  requires: MapSet.t(module())
}
```

Each source node can be classified as:

- `:trusted`: walker understands the context.
- `:opaque`: user macro or DSL call boundary.
- `:untrusted_descendant`: descendant of opaque code.
- `:quoted`: quoted code, skipped by default.
- `:generated`: generated or external source, skipped.

Mutators may only operate on trusted nodes unless explicitly configured otherwise.

### Walker Policy

The walker emulates only special forms and known Kernel constructs needed for mutation context.

It tracks:

- `defmodule`, `def`, `defp`, `defmacro`, `defmacrop`, `defguard`, `defguardp` heads.
- Function clauses and default argument surfaces.
- `when` guard context.
- Pattern contexts in `case`, `fn`, `with`, `for`, `receive`, `try/rescue/catch`.
- `alias`, `import`, `require`, and `use` as environment-changing forms.
- Module attributes and attribute values.
- `quote`, `unquote`, and `unquote_splicing` boundaries.

It does not expand user macros. When it sees an unknown macro or DSL call:

- Record the call site.
- Mark the call body/children as opaque unless it is a known safe block form.
- Do not generate mutants below that boundary.
- Emit skip diagnostics if there were otherwise-looking mutation targets inside.

### New Mutator Surface

#### Literal Mutators

Trusted function-body literals:

- Integer: `0 -> 1`, `1 -> 0`, `n -> n + 1`, optionally `n -> n - 1`.
- Float: `0.0 -> 1.0`, non-zero finite float -> `0.0` or `f + 1.0` with equivalent filters.
- Boolean: `true <-> false`.
- Binary string: non-empty -> `""`; empty -> configured skip by default.
- Atom: limited configured atom replacements only; do not create arbitrary atoms by default.
- List/map/tuple emptying only when low-noise rules are defined.

#### Pattern Mutators

Pattern mutations are high-risk/noisy and should start conservative:

- Replace pinned variable with unpinned variable only behind opt-in.
- Replace literal pattern constants using literal mutator rules.
- Swap `_` and named variable only behind opt-in.
- Tuple/list arity mutations are skipped by default because they often create non-viable mutants.

#### Attribute Mutators

v1 fallback attribute support becomes more precise:

- Mutate trusted literal attribute values.
- Classify whether the attribute influences compile-time shape.
- Route all attribute mutants through fallback compile.

### Engine Routing

v2 still routes by context:

- Trusted function body literals: schema engine.
- Trusted dispatch body nodes: schema engine from v1.
- Guards: fallback unless wrapper-schemata threshold from v1 metrics is crossed.
- Patterns: fallback initially, because pattern schemata are not expression-position safe.
- Module attributes: fallback.
- Opaque/untrusted/quoted/generated: skipped.

### Wrapper Guard Schemata Decision

Do not automatically build wrapper-function guard schemata in v2.

Decision rule:

- If v1/v1.5 telemetry shows fallback wall-clock consistently above roughly `25%` on representative projects, design wrapper guard schemata.
- Otherwise keep guard mutations in fallback and spend v2 effort on walker/literal precision.

If built, wrapper guard schemata require a separate SPEC because they must preserve:

- Multi-clause ordering.
- Default argument generated clauses.
- `@spec` and docs association.
- `defmacro` caller semantics.
- `mutant_id == 0` exact behavior.

### Architecture Changes

New components:

- `Mut.EnvWalker`: source walker producing `EnvSnapshot` records.
- `Mut.EnvOracle`: index from source span / AST path to env snapshots.
- `Mut.OpaquePolicy`: known-safe forms and known-opaque boundaries.
- `Mut.SourceSpan`: common span and byte-offset utilities used by schema and fallback.
- `Mut.Mutator.Literal.*`.
- `Mut.Mutator.Pattern.*`.

Changed components:

- `Mut.Orchestrator` merges tracer and env-walker oracle data.
- `Mut.Context` gains `env_snapshot` and `trust_level`.
- `Mut.Reporter` reports skipped opaque/generated/quoted regions with counts.
- `Mut.SchemaPlacer` supports literal schema insertion in body expression positions.

### Data Merge

v2 context construction:

1. For a source AST node, lookup env snapshot by source span and AST path.
2. If the node is dispatch-shaped, also lookup tracer dispatch site.
3. If both exist and disagree on file/function/context, mark node ambiguous and skip.
4. If env snapshot is untrusted, skip unless mutator explicitly supports that trust level.
5. Build `Mut.Context` with both `oracle_site` and `env_snapshot`.

### Test Selection

v2 can use v1.5 coverage selection unchanged.

New non-dispatch mutants map to coverage by:

- Exact source line for literals.
- Enclosing function for pattern and attribute fallback.
- Static dependency fallback when coverage is missing.

### Incremental History

v2 should introduce persistent history if v1.5 coverage selection is stable.

History key:

```text
stable_mutant_id + source_digest + selected_tests_digest + config_digest
```

Reusable outcomes:

- Previously killed: reuse when source and killing test are unchanged.
- Previously survived: reuse when source and all selected tests are unchanged.
- Previously timed out: reuse cautiously only when source and selected tests are unchanged and timeout config is unchanged.

History should be optional and conservative. Incorrect reuse is worse than a slow run.

### Metrics

v2 must report:

- Mutants by oracle source: tracer, env walker, both.
- Mutants by engine: schema, fallback.
- Mutants skipped by trust level.
- Literal/pattern invalid rate by mutator.
- Fallback wall-clock percentage.
- Coverage selection fanout for new non-dispatch mutants.
- History hit rate if history is enabled.

### Risks

- Env walker drift from Elixir compiler semantics.
- False confidence around unknown macros if opaque policy is too permissive.
- Literal mutators can increase equivalent/noisy mutants.
- Pattern mutators can produce many invalid mutants.

### Acceptance Criteria

- v2 preserves all v1/v1.5 behavior for dispatch-shaped mutants.
- Env walker never expands user macros.
- Opaque macro descendants are skipped by default.
- Literal body mutants can run through schema engine.
- Pattern and attribute mutants route through fallback unless explicitly safe.
- Reports clearly distinguish unsupported, opaque, generated, and no-coverage skips.
- Invalid rate for new mutators is tracked and can be gated in CI.

## Milestone Split

### v1.5 (two milestones)

**M15 — Coverage Infrastructure And Phase Timing**
- Phase timings added to `Mut.Metrics` and reported in terminal + Stryker JSON.
- `_build/mut_coverage` build-path role added to the Build-Path Contract.
- Baseline test runner under `:cover` (per file/module), `async: false` during collection only.
- Normalized line/function coverage in `Mut.CoverageOracle`.
- No caching: recollect every run.
- Stable IDs unchanged.
- Coverage writes only to isolated build path; user `_build/test` untouched.

**M16 — Coverage Selector And Smoke**
- `--selection static|coverage|coverage_with_static_fallback` CLI flag (default `static`).
- Selector priority chain: exact line → enclosing function → static → all tests.
- In-run last-killer prioritization by module (NO persistent history).
- Selection metrics + selection mode reported.
- Smoke run on plug_crypto + Decimal retry; BENCHMARKS update.
- Acceptance per criteria above.

### v2

- Lean env walker.
- Env oracle merge with tracer oracle.
- Literal mutators in trusted function bodies.
- Conservative pattern mutator framework.
- Better attribute classification.
- Optional incremental history.

## Open Questions

Resolved in v1.5 scope:

- ~~Should v1.5 coverage attribution target test files/modules only, or per-test-case?~~ Files/modules only in v1.5; case-level deferred.
- ~~Should source probes replace `:cover` if `:cover` produces too much fanout?~~ `:cover` only in v1.5 (Option B); source probes deferred to v2 if needed.

Open for v2:

- Should v2 literal atom mutations be disabled by default to avoid atom-table and semantic-noise risks?
- Should pattern mutators ship as opt-in experimental only?
- Should persistent history be v2 or v2.1, after coverage selection proves stable?
- If v1.5 Decimal acceptance fails (coverage doesn't move the needle), does parallel-worker execution become a v1.6 milestone or fold into v2?
