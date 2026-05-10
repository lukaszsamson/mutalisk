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

- Trusted function body literals: fallback in v1.9; schema routing is
  deferred until literal encoding can be reconciled without stable-id churn.
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
- Literal body mutants run through fallback in v1.9; schema routing is
  allowed later only with an explicit stable-id migration decision.
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

### v1.6 (two milestones — performance hardening)

v1.6's theme: parallel workers as the production default. Empirical validation + hardening + light documentation. NOT new features.

The PROMPT_16 mission landed parallel-worker prototype, fallback Mix-bypass, and persistent-BEAM measurement spike. v1.6 takes that prototype to production quality.

**M17 — Parallel Hardening + Default + Fallback Recompile Tests**
- Validate `--concurrency 1/2/4/8` on demo_app, plug_crypto, Decimal. Document speedup curve.
- Outcomes byte-identical at c=1 vs c=4 across all targets.
- Decimal `--concurrency 4` ≤ 15 min on the reference machine.
- Zero invalid fallback mutants from recompile infrastructure on Decimal.
- Audit + harden `Mut.LastKiller` and `Mut.Sandbox` for concurrency.
- Flip default concurrency to `min(System.schedulers_online(), 4)`.
- Reports include concurrency metadata.
- Doc + targeted tests for elixir-direct fallback recompile path.
- Improved diagnostics distinguishing compile / dependency / runtime failures.

**M18 — v1.7 Persistent Worker Design**
- Convert `bench/spike/persistent_beam.exs` measurements + V16 recommendation into `V17_PERSISTENT_WORKER.md`.
- Define `Mut.Worker.Persistent` contract, lifecycle, isolation model.
- ExUnit state reset strategy + unsupported test patterns.
- Crash recovery + concurrency interaction.
- v1.7 acceptance sketch + implementation cost estimate.
- Single docs-only commit; no production code.

### v1.7 (one milestone, opt-in)

**M19 — Persistent Worker (opt-in)**

Per `V17_PERSISTENT_WORKER.md` (delivered in M18, on master). Persistent BEAM per sandbox; `:persistent_term` flip per mutant; in-process ExUnit re-run with explicit reset hooks for ETS / Application env / registered-process leak vectors; in-process fallback recompile via `Kernel.ParallelCompiler.compile_to_path/2` + `:code.load_binary/3`; crash detection via Port monitoring with fallback-to-mix-worker after a configurable retry threshold; new `--worker-type mix|persistent` flag.

**Default stays `mix` for first v1.7 release.** Conservative ship discipline: same pattern as v1.5's static-first / v1.6's concurrency-cap-4-first. Flip default to `persistent` in a follow-up release after real-project validation. Detailed scope in `PLAN.md` M19 section.

**v1.7 raises minimum Elixir to 1.18.0** (from v1's `>= 1.17.0`). Rationale: V17's reset strategy depends on ExUnit internals (`ExUnit.OnExitHandler`, `ExUnit.Server.modules_loaded/1`, `ExUnit.configure(only_test_ids: ...)`) that are stable from 1.18 onward. Pre-1.18 users stay on mutalisk 1.6.x. Recorded as a breaking change in CHANGELOG.

#### Acceptance correction from M18's draft

V17 originally proposed "Decimal ≤2 min at c=4" as a hard gate. **That target is too aggressive.** Decimal currently has 21 timeout mutants at the 60s per-mutant cap; even with infinitely-fast non-timeout mutants, the lower bound at c=4 is `21 × 60s / 4 ≈ 315s` (5.25 min). Treat ≤2 min as aspirational. Gate on **material improvement over M17's 11 min** instead. Reducing per-mutant timeout duration or changing timeout classification semantics is explicitly out of scope.

#### Outcome-identity bar tuned for timeouts

Same Survived stable-id set as `mix` worker. Killed/timeout timing flaps near the 60s cap are documented as variance, not regression. M17 already saw 4-8 mutants flap on Decimal — that's a property of the test suite under cold-start variance, not a parallelism or worker-type bug. Persistent workers will see similar (different) flap patterns; document, don't gate.

#### Target acceptance

- Per-mutant median wall <50 ms on demo_app (steady-state, post-warmup).
- Decimal wall at `--concurrency 4` improves materially over M17's 11.0 min (no hard threshold; document the actual number).
- Same Survived stable_id sets between worker types on demo_app, plug_crypto, Decimal.
- New `e2e_persistent` `bin/verify` layer runs demo_app schema + fallback at c=4 with persistent workers.
- Decimal fallback bucket continues to land at 0 invalid (the M17 Phase B win holds).
- `--worker-type mix` is the default and is regression-tested forever.
- Reset-hook leak fixture (intentional Application env / ETS / registered-process / `:persistent_term` mutation) proven cleaned between mutants.

#### 7-step sequencing (commit pacing within M19)

1. Schema-only persistent worker skeleton (also bumps `mix.exs` Elixir requirement to `>= 1.18.0`).
2. Reset hooks + leak fixture.
3. Test-file run filtering via `ExUnit.configure(only_test_ids: ...)` (stable from 1.18+).
4. Parallel persistent workers via M17's `SandboxQueue`.
5. Fallback in-process recompile.
6. Crash detection + retry-then-fallback to `mix`.
7. Public `--worker-type` flag + `e2e_persistent` layer + benches + CHANGELOG (records both the new flag and the Elixir-version bump).

The intermediate "schema-only persistent" state (steps 1-4) is not independently shippable to users. The public flag is exposed only at step 7 (after schema + fallback + crash recovery all work).

#### Implementation cost (refined)

~930 LOC total (worker + protocol + reset hooks + run filter + fallback recompile + crash recovery + flag + tests). M18's V17 doc enumerates per-vector reset hooks and crash recovery; the line count grew from PROMPT_16's 590 estimate accordingly.

#### Highest risks

1. **State leaks between mutants** from undiscovered reset vectors (the leak fixture in step 2 catches the obvious ones; subtle leaks may surface only on real projects). Single biggest correctness risk: silent leaks produce wrong results that look right.
2. **In-process fallback recompile** (step 5) interfering with the persistent BEAM's already-loaded modules. Tested against demo_app fallback first; may need a transient compile process within the persistent BEAM if conflicts surface.
3. **ExUnit private-API drift across patch releases**. Pinned to >= 1.18.0; a future Elixir minor that removes/renames `ExUnit.OnExitHandler` or `ExUnit.Server.modules_loaded/1` would break v1.7 entirely. Acceptable risk — mutalisk users can stay on the last-compatible mutalisk release until we adapt.

#### `mix` worker is permanent

Even after persistent becomes default in a v1.8+ follow-up, `mix` stays as the validated safety hatch and is regression-tested forever. Some user code patterns (ETS tables tests don't create, mocked modules without per-test cleanup, per-process compilation state, tests that crash the BEAM) genuinely cannot run safely in a persistent worker. `--worker-type mix` is the documented escape.

### v1.8 (two milestones — perf-realization for persistent worker)

v1.7 shipped persistent worker as opt-in supported with byte-identity proven on demo_app, plug_crypto, Decimal. But v1.7 BENCHMARKS shows persistent is SLOWER than mix on plug_crypto and Decimal at c=4. v1.8 closes that gap.

**Theme**: make persistent workers worth using, not just correct.

**Default does NOT flip in v1.8.** Default flip is a separate v1.9+ decision based on v1.8's empirical results. Persistent stays opt-in via `--worker-type persistent`.

**M20 — Persistent performance diagnostics + targeted optimization**

Combined diagnostic-and-fix milestone. Phase A measures per-phase overhead; Phase B applies targeted optimizations based on findings.

Phase A (diagnostics, lands first):
- Per-phase timings: boot, project app startup, test file load, per-mutant ExUnit run, reset hooks (per-vector), filter lookup.
- Crash / restart / filter-miss counts.
- Memory dimension via `:erlang.memory(:total)` snapshots.
- New `mutalisk.persistent` block in Stryker JSON + terminal output.
- Initial bench at c=1/4 on demo_app, plug_crypto, Decimal identifies dominant overhead per target.

Phase B (targeted optimization based on Phase A findings):
- Most likely fix: scope `Application.ensure_all_started/1` to project app + declared deps only, not every `.app` in `_build/mut_schema/lib/*/ebin/`. v1.7 F2 added the start-everything path for correctness; the optimization is starting fewer apps without breaking that correctness.
- Profile and optimize reset_leaks/1 implementations (NOT skip them).
- Cache discovered app list and test file list per sandbox.
- Lighter result protocol if formatter is dominant overhead.

Phase B acceptance: persistent at default c=4 ≥1.5× faster than mix on at least one of plug_crypto or Decimal. demo_app remains faster. byte-identity preserved.

Fallback acceptance (if 1.5× isn't reachable): Phase A diagnostics ship anyway; BENCHMARKS documents residual overhead with root cause; v1.8 ships as "diagnostics released, perf gap documented."

**M21 — In-process fallback recompile (conditional)**

Run only if M20 Phase A measurements show fallback recompile is dominant overhead on Decimal-class projects (>25% of total wall-clock at c=4). Otherwise defer indefinitely.

If executed: `:code.purge/1` + `:code.load_binary/3` inside persistent BEAM; restart-then-mix-fallback on purge/recompile failure; module-redefinition state added to reset hooks.

Acceptance: byte-identity for fallback bucket on all three targets; measurable Decimal fallback wall-clock improvement; no increase in invalid/error mutants.

**Default flip gate (carried forward to v1.9+)**

Persistent becomes default only when:
- byte-identity on all three targets ✓ (already met in v1.7).
- Persistent FASTER than mix at c=4 on plug_crypto AND Decimal.
- bin/verify green at default.
- `--worker-type mix` permanent escape hatch.

If v1.8 lands the speed bar, default flip is v1.9 work. If v1.8 documents a fundamental limitation, persistent stays opt-in indefinitely.

**Explicitly forbidden in v1.8 (correctness hazards)**

- Skipping reset vectors via dirty flags. Re-introduces the v1.7 F2 failure mode.
- Disabling `Application.ensure_all_started/1` for project apps. v1.7 F2 proved this is required for correctness on plug_crypto-class projects.

### v1.9 (two milestones — maturation + expanded mutation surface)

v1.7 + v1.8 only validated 3 projects (demo_app, plug_crypto, Decimal). v1.9 matures persistent-worker operations and adds a narrow opt-in literal surface without changing defaults.

**Default `--worker-type` does NOT flip in v1.9.** That's v1.10 territory, gated on expanded validation.

**Default `--selection` does NOT flip in v1.9.** Coverage remains opt-in until the expanded validation milestone proves the interaction with persistent workers on more real projects.

**M22 — Persistent reliability + observability + config + guide**

- `--test-timeout-ms N` flag and `config :mut, test_timeout_ms: N`. Default 10_000 (v1.8's value). Plumbs to mix-spawn `--timeout` and persistent runner ExUnit config. One-flag opt-out for users with legitimately slow tests.
- Persistent metrics surfaced in summary always when persistent is active (M20 already collects them; M22 promotes to terminal display).
- Single explicit warning threshold: filter-miss > 25% OR crash > 10% OR fallback-compile-error > 5% triggers a one-line "consider --worker-type mix" hint at run end. No auto-mode-switching.
- Coverage + persistent interaction validation in the existing e2e_persistent layer. Currently UNTESTED; closes a real silent-drift risk.
- Regression fixture for `Application.start/2` + named ETS tables, mirroring the v1.7 F2 root cause.
- New `docs/PERSISTENT_WORKER_GUIDE.md` covering when to use persistent, supported/unsupported project shapes, metric interpretation, fallback advice.

**M23 — Body-context literal mutators**

Two new mutators, narrowly scoped:
- `Mut.Mutator.IntegerLiteral`: integer literals in body context only. Replacements: `0 → 1`, `1 → 0`, `n → 0`, `n → n + 1`.
- `Mut.Mutator.BooleanLiteral`: boolean literals in body context only. Replacements: `true ↔ false`.

Walker extension `Mut.AstWalk.body_literal_candidates/1` discovers literals in function-body positions (not guards, not patterns, not quote/unquote). v1.9 routes body literals through the fallback engine because the literal walker uses parser `literal_encoder` metadata while the schema placer uses bare-literal AST. Schema routing is deferred unless benchmarks justify a literal-encoding stable-id migration.

Float, string, atom, list, map, tuple literals deferred to v2 alongside the lean env walker, where their pattern-position vs body-position discrimination needs richer context tracking than v1.9's syntactic walker provides.

Function-call deletion and return-value replacement remain deferred indefinitely (high false-positive risk).

**M24 — Body-literal real-world validation (v1.10 candidate)**

- Validate `--enable body_literal` on real OSS targets before expanding the literal surface or changing defaults.
- Coverage default flip remains deferred; `--selection static` stays the default in v1.9.
- Validate persistent worker behavior on additional OSS targets:
  - `nimble_options` — small validation library, baseline.
  - `gettext` — compile-time macros, tests schema build robustness.
  - `ecto` — Ecto.Query macros + schema generation. Tests both schema build AND persistent's reset hooks (Ecto.Repo state).
  - `mox` — module-replacement mocking. CRITICAL test for persistent's :code-server state handling.
  - `jason` — StreamData property-based tests. Mutation testing on StreamData is intrinsically non-deterministic; documented as informational target with caveat.
- BENCHMARKS.md gains a v1.10 body-literal validation section per target × worker × body-literal enablement.
- `PERSISTENT_WORKER_GUIDE.md` gains target-specific notes including any unsupported patterns surfaced.
- v1.10 default-flip gate remains documented in PLAN.md.

**v1.10 default `--worker-type` flip gate** (carried forward):
- ≥4 of 5 new OSS targets clean (byte-identical, persistent faster or comparable).
- Zero new unsupported-pattern categories affecting common project shapes.
- `--worker-type mix` permanent escape hatch.
- Persistent ≥1.5× faster than mix on plug_crypto, Decimal, AND 2 of M24's new targets.

If validation surfaces unsupported patterns affecting common project shapes (Phoenix, Ecto, mox-based tests), v1.10 scope shifts to addressing them and worker default stays `mix`.

**Explicit StreamData treatment**: property-based tests with random generators violate byte-identity expectations. Two acceptable approaches per M24's subagent brief: (1) pin StreamData seed for reproducibility, or (2) document target as informational. StreamData target results do NOT gate v1.9 acceptance.

### v1.10 (two milestones — validation + decisions)

v1.9 deferred the OSS validation matrix because external-repo probing was sandbox-blocked. v1.10's job is to actually run that matrix and use the data to make two decisions: body-literal default policy + persistent worker default-flip.

**One bench cycle answers both questions.** Running 5+ OSS targets × `{mix, persistent}` × `{baseline, body_literal}` produces all the data needed for both decisions plus side-validations (coverage default-flip field validation, M22 warning threshold tuning, coverage + body_literal interaction).

v1.10 is **two milestones**, not four. M25 runs the matrix and decides body-literal scope. M26 uses the same data to decide persistent default-flip.

**M25 — Validation matrix + body-literal decisions**

Pin SHAs for nimble_options, gettext, ecto, mox, jason (and optionally plug). Run the four-step-per-target matrix (mix baseline, persistent baseline, mix + body_literal, persistent + body_literal). Capture per-target Stryker JSON, terminal output, phase timings, persistent metrics.

Two decisions output:

1. **Body-literal default policy**: default-on (if average kill rate ≥60% and equivalent rate <20%), trim table (drop `n → n+1` if survivor rate >50%), or keep opt-in (if any target shows invalid body-literal mutants or persistent-specific drift).
2. **Body-literal routing**: stay fallback (if contribution <15% of largest target's wall-clock), or migrate to schema (deferred to v1.11+ as a stable_id migration milestone).

Side validations: coverage default-flip on real OSS, coverage + body_literal interaction, M22 warning threshold tuning.

**M26 — Persistent worker default-flip decision**

Reuses M25's matrix data (no new bench cycles). Apply the v1.10 default-flip gate: ≥4 of 5 OSS targets clean, zero new unsupported patterns, persistent ≥1.5× faster on plug_crypto + Decimal + 2 of M25's new targets.

Three possible outcomes: flip default to persistent, keep mix default with extended docs, or defer flip and scope v1.11 fixes for unsupported patterns.

**v1.11 horizon** (not v1.10 scope):
- Body-literal schema migration if M25 Decision 2 demands it (stable_id migration).
- Persistent worker fixes for unsupported patterns surfaced in M25/M26.
- Or env walker (the long-deferred v2 architecture work) if v1.10 closes cleanly.

### v1.11 (4 committed + 3 stretch milestones)

M26 closed v1.10 with Outcome 3 (defer default-flip; scope persistent fixes for v1.11). v1.11's theme is **widen real-world validation while closing the biggest persistent correctness gaps** — and restart mutator-catalog growth, which v1.9 and v1.10 both deferred.

**Committed milestones (sequenced):**

**M27 — OSS validation harness expansion + drift observability.** v1.10's lesson: 3 reference targets hide entire bug classes. M27 makes real-life coverage a permanent asset — pin ≥5 additional OSS targets (plug, phoenix_html/template, telemetry_metrics, broadway/oban, finch/mint), classify each as clean/drift/unrunnable/informational, and ship a drift-bucketing tool that auto-partitions mix-vs-persistent stable-id status diffs by heuristic class. Also adds a persistent boot-time warning for known-bad target signatures (mox/ecto/gettext) so users get told to use `--worker-type mix` rather than silently hitting drift. Closes the user-experience gap M25's findings opened.

**M28 — `Mox.Server` reset hook.** Cheapest correctness fix; banks a v1.11 win regardless of M29's spike outcome. Adds Mox-aware reset to the persistent runner (no-op when Mox isn't loaded). Acceptance: mox baseline drift drops to V17 timeout-flap acceptance.

**M29 — Persistent recompile isolation spike.** Ecto + nimble_options drift may share a root cause: in-process `Code.compile_file/1` leaks compile-time state mix-spawn doesn't. Spike compares three modes (current in-process, helper-process compile, mix-spawn fallback) on nimble_options + ecto. Output is a written decision doc, not shipped code. May subsume M30 + the parse-class residual at once.

**M30 — Ecto warm-state closure.** Sequenced after M29 because the spike's outcome may eliminate most of this work. If isolation insufficient: target-specific ETS-cache reset + Repo process-tree teardown. If isolation closes drift: validate residual is V17-acceptance and document.

**Stretch milestones (commit only with budget):**

- **M31 Gettext compatibility decision** — fix via `Kernel.ParallelCompiler` parent OR formally exclude.
- **M32 Affected-test selection spike** — sharpened kill criterion: ANY silent-survivor delta on ANY target kills the optimization. Survivor drift is correctness regression masquerading as a perf win.
- **M33 Comparison-operator boundary mutator** — one narrow, fallback-safe schema mutator (`<` ↔ `<=`, `>` ↔ `>=`). Restarts catalog growth without env walker. Atoms/strings/maps/lists stay v2.

**Explicitly NOT a milestone**: upstream Elixir `Macro.to_string/1` heredoc fix revert. Unlikely to land in the v1.11 window. Tracked via CHANGELOG note + `# TODO` at the workaround site; revert is a single PR when upstream ships.

**Default-flip gate (revised)**: `--worker-type` flips iff M28 closes mox-drift, M30 closes ecto-drift, AND gettext-class is either fixed (M31 path i) or formally documented as mix-only (M31 path ii). The flip is **not a v1.11 goal** — v1.11 ships even if the gate stays unmet. M29's spike output may rewrite this gate for v1.12.

### v2

- Lean env walker.
- Env oracle merge with tracer oracle.
- Float, string, atom, list, map, tuple literal mutators in trusted function bodies (M23 handled integer + boolean only).
- Pattern-position literal mutators.
- Conservative pattern mutator framework.
- Variable mutators.
- Better attribute classification.
- Optional incremental history.
- Wrapper guard schemata (if v1's fallback metrics ever justify it; v1.8 measurements suggest fallback is not dominant overhead).

## Open Questions

Resolved in v1.5 scope:

- ~~Should v1.5 coverage attribution target test files/modules only, or per-test-case?~~ Files/modules only in v1.5; case-level deferred.
- ~~Should source probes replace `:cover` if `:cover` produces too much fanout?~~ `:cover` only in v1.5 (Option B); source probes deferred to v2 if needed.

Open for v2:

- Should v2 literal atom mutations be disabled by default to avoid atom-table and semantic-noise risks?
- Should pattern mutators ship as opt-in experimental only?
- Should persistent history be v2 or v2.1, after coverage selection proves stable?
- If v1.5 Decimal acceptance fails (coverage doesn't move the needle), does parallel-worker execution become a v1.6 milestone or fold into v2?
