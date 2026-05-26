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

**v1.11 outcome (2026-05-10):** all 7 milestones closed across 13 commits. Default-flip gate **closed structurally**, not on engineering shortfall: M28's hook is correct but the residual mox-class drift is cluster/peer-state (not local Mox.Server state); M29's spike rejected helper-process isolation because the leak class is BEAM-global ETS, not process-local; M30 confirmed Ecto's RuntimeError-class drift is structural (mix-spawn re-runs `Application.start/2` per fallback mutant; persistent doesn't); M31 took Path (ii) and formally classified gettext as mix-only. M32 shelved on risk-surface analysis. M33 was already shipped in v1.5 (commit `06e8398`); v1.11 work was bench validation only. Final mix-only catalogue: Ecto/`:ecto_sql`, Gettext, clustered Mox, HTTP-clients with pooled state (mint/finch/nimble_pool — surfaced by M27, not yet in boot warning), and the M27 SchemaPlacer escaped-quote crash class (phoenix_html/plug/phoenix_pubsub — Mutalisk-owned regression, both worker types affected). Persistent worker remains opt-in. Default `--worker-type` stays `mix`.

### v1.12 (4 committed milestones — stabilization)

v1.11 closed with two M27 follow-throughs deferred (the SchemaPlacer escaped-quote crash and the pool-warm-state boot-warning gap) and the default-flip gate structurally closed. v1.12's theme: **stabilize the expanded harness; do not add broad new mutation surface until the env walker.**

**Default `--worker-type` does NOT flip in v1.12.** The structural drift classes (Ecto, Gettext, clustered Mox) cannot be closed by reset hooks; v1.11 documented this. v1.12 may sharpen the mix-only catalogue but will not move the default.

**Default `--selection` does NOT flip in v1.12.** Coverage stays opt-in until persistent stabilization completes.

**M34 — `Mut.SchemaPlacer` escaped-quote fix.** Highest priority: Mutalisk-owned regression blocking `phoenix_html`, `plug`, and `phoenix_pubsub` under both worker types. Fix `render/1` round-trip for strings containing escaped quotes (`\"…\"`), escaped backslashes, and related escape sequences. Add fixture regression covering escaped-quote content in body and module-attribute positions. Re-bench the three previously-blocked targets in both worker modes; reclassify from `unrunnable`. Acceptance: schema build no longer crashes; both worker types reach mutant execution; existing `golden_instrument` layer remains green.

**M35 — Pool-warm-state boot warning + drift bucketer hardening.** Bundled because both are M27 follow-throughs; neither alone justifies a milestone. Extend persistent boot-warning catalogue with HTTP-client / pool signatures: `:mint`, `:finch`, `:nimble_pool`. Drift bucketer gains per-bucket unit tests (especially `:pool_warm_state`), `--json` output for CI, report paths and sample stable_ids in output. Acceptance: bucketer remains <5% unclassified on M25+M27 corpus; pool boot warning fires correctly on mint/nimble_pool fixtures, silent on plug_crypto/Decimal/demo_app; `PERSISTENT_WORKER_GUIDE.md` documents pool signatures as persistent-risk (not hard mix-only — M36 decides that).

**M36 — Pool-warm-state characterization spike.** Do not jump to reset hooks; characterize the leak class first (the answer may be "classify mix-only," mirroring M30). Three modes on `mint` and `nimble_pool` (and `finch` if toolchain permits): current persistent in-process, aggressive process-tree reset (kill+restart pool supervisors between mutants), restart-project-apps-per-mutant. Measure drift partition vs `mix`, wall-clock cost, memory. Identify dominant leak vector: process tree, ETS registry, sockets, or `Application` env. **Parse-class subsection**: re-examine the 4 residual parse-class mutants (2 nimble_options, 2 mox) in light of the spike's findings; fold the fix into the recommended path if applicable, otherwise document and accept as a known persistent limitation. Output: written decision doc at `docs/spikes/M36_pool_warm_state.md`. Three options: reset hook (if cheap and effective — promote to implementation in same milestone), mix-spawn reroute for affected mutants, or formal mix-only classification.

**M37 — Mutator-surface decision.** Three releases without a new mutator weakens the value prop, but the env walker is still v2 work. Decide explicitly: ship one narrow schema-safe extension OR formally defer all catalog growth to v2. Candidate: `Mut.Mutator.ComparisonNegation` (`==` ↔ `!=`), schema-routed via existing dispatch oracle, structurally analogous to M33's ComparisonBoundary. Atoms/strings/maps/lists/list-construction stay v2. Decision criteria: schema-routed (no fallback-only), unambiguous in body context (no env-walker dependency), stable_id-safe (no migration). If shipped: validate on plug_crypto, Decimal, and ≥2 OSS targets; report kill rate as observation. Acceptance: either (a) one new schema-routed mutator landed and validated on ≥4 targets, OR (b) decision doc at `docs/spikes/M37_mutator_surface.md` formally deferring catalog growth to v2. Both outcomes ship v1.12.

**Explicitly NOT in v1.12:**
- Reopening helper-process recompile isolation (M29 rejected on root-cause grounds; reopen only if a real target shows drift it demonstrably closes).
- Reopening affected-test selection (M32 shelved; reopening criteria documented there).
- New CLI flags beyond M35's `--json`.
- Persistent default flip (closed structurally).
- Coverage default flip (deferred).
- Stable_id input changes.
- Reopening Ecto / Gettext / clustered-Mox persistent support on incremental hooks (mix-only is documented; reopen only on a fundamentally different approach).

**v1.12 outcome (2026-05-10):** all 4 milestones closed. M34 narrowed `Mut.SchemaPlacer.strip_heredoc_delimiters/1` to `:<<>>` only — sigil heredocs now round-trip via `Macro.to_string/1`'s native sigil emission, unblocking phoenix_html (clean), plug (drift, ~5% supervisor-init class), and phoenix_pubsub (unrunnable for an unrelated cluster-test reason). M35 added `:mint` / `:finch` / `:nimble_pool` to the boot-warning catalogue under a single `:pool` signature, added `:supervisor_init` heuristic + `--json` to the drift bucketer, and dropped aggregate unclassified rate from 6.69% to 0.30% on the M25+M27+M34 corpus. M36 implemented `apps_restart` mode as the strongest reset hook the spike could land and concluded reset hooks are ineffective on pure-library OTP apps (mint/nimble_pool have no `:mod` supervisor callback); pool-class is "supported with caveat" rather than mix-only. M37 closed the mutator-surface decision via outcome (a) — `Mut.Mutator.ComparisonNegation` was already shipped in v1.5 (commit `06e8398`); v1.12 work was bench validation across 8 targets (kill rates 75–100%). Default `--worker-type` stays `mix`; default `--selection` stays `static`.

### v1.13 (2 milestones — doc closure + env walker design)

v1.12 closed cleanly but with release-doc inconsistencies (the boot-warning catalogue table claims v1.11 vintage despite the M35-added pool row; the guide contains a paragraph claiming pool projects are "NOT yet in the boot-warning catalogue"; the pool row says "M36 may close this class" when M36 explicitly chose not to; BENCHMARKS.md plug row's bucket annotation predates M35's `:supervisor_init` heuristic; detector moduledoc catalogue text predates M28/M30 narrowing of mox/ecto descriptions). v1.13 also retires two spike-only env vars (`MUT_PERSISTENT_COMPILE_MODE=helper_process` from M29, `MUT_PERSISTENT_POOL_RESET=apps_restart` from M36) whose decisions concluded "don't ship."

The substantive v1.13 work is the env-walker design spike. The recurring "deferred to v2 with the env walker" has been sitting in the HLD since v1.5; v1.13 is when that gets actually scoped.

**Default `--worker-type` does NOT flip in v1.13.** Closed structurally.

**Default `--selection` does NOT flip in v1.13.**

**M38 — v1.12 documentation closure + spike-env-var cleanup.** Mechanical milestone. Doc fixes: rename `docs/PERSISTENT_WORKER_GUIDE.md`'s "v1.11 catalogue" → "v1.12 catalogue"; delete the stale "pool not yet in catalogue" paragraph; rewrite the pool row's "M36 may close" to reflect M36's actual finding (reset hooks ineffective on pure-library OTP apps; pool drift is `mix=Survived → persistent=Killed`, persistent may be more thorough rather than wrong); update plug v1.19.1's BENCHMARKS row from `unclassified ×16 + parse_class ×1` to `:supervisor_init ×16 + parse_class ×1`; align detector moduledoc catalogue text with the `@signatures` data table (add `:pool` row, narrow `:mox` to clustered/peer-state residual, narrow `:ecto` to supervisor-init structural drift). Spike-env-var cleanup: remove `MUT_PERSISTENT_COMPILE_MODE=helper_process` + `compile_via_helper_process/1`, `MUT_PERSISTENT_POOL_RESET=apps_restart` + `reset_pool_apps/0`, `reset_pool_us` from `MUT_RUN_METRICS`, and forwarding entries from `Persistent.port_env/1`. Resurrect from git if a future spike needs them. Policy additions: `:supervisor_init` policy note distinguishing Ecto-class (mix-only, structural) from low-rate plug-class drift (supported); document `mix mut.drift --json` schema with examples (schema considered stable for CI from this point). Acceptance: grep-based stale-phrase checks pass; spike env vars do not appear in `lib/`; `bin/verify` green.

**M39 — Env walker design spike.** Design the env walker that unblocks v2's mutator catalog (string/atom/list/map/tuple body literals, pattern-position literals, variable mutators, better attribute classification). Spike output is a written design doc; no production code ships. A throwaway prototype is acceptable to land the cold-compile cost measurement, but must not enter `lib/`.

Reference implementation to study (NOT to copy): `~/elixir_sense/lib/elixir_sense/core/compiler.ex` and related modules. ElixirSense's compiler module performs an AST traversal of module and function bodies using public `Macro.Env` APIs. It does NOT invoke macros, evaluate code, or run module callbacks — expansion is best-effort, which is exactly the contract the mutalisk env walker needs. ElixirSense expands modules and functions a bit differently than `:elixir_expand` does, and goes marginally further than mutalisk needs (it expands more constructs to collect IDE-grade metadata). The mutalisk walker should aim for the strict subset that establishes context without collecting symbol-table data.

Why NOT use `:elixir_expand` directly: `:elixir_expand` performs full evaluation + expansion, writes modules and functions to internal compiler ETS tables, and interacts with the real compiler. It is not isolatable, parallelizable, or safe to run inside a long-lived persistent worker without state contamination. ElixirSense's approach (best-effort traversal using only public `Macro.Env` APIs) is what makes the walker usable as a host-side oracle pass.

Design doc deliverable at `docs/spikes/M39_env_walker.md` must answer:

1. **Context discrimination** — concrete AST-walk strategy mapping each context (body / guard / pattern / quote / macro) to its `Mut.EnvSnapshot` classification (`:trusted` / `:opaque` / `:untrusted_descendant` / `:quoted` / `:generated`).
2. **User macro opacity policy** — non-negotiable: walker does NOT expand user macros. Document how unknown macro calls are classified and confirm the no-expansion property by inspection.
3. **Public-API surface** — enumerate `Macro.Env` APIs depended on. Note any "public but undocumented" ones (similar to v1.7's ExUnit private-API reliance, which forced the Elixir 1.18.0 floor). If the walker forces a higher Elixir floor, that's a v2 release-note item.
4. **Stable-ID strategy** — declare whether the env walker can be added without a stable_id migration (preferred) or forces one. Migration shifts the v1.14 acceptance bar to a stable_id migration milestone.
5. **Cold-compile cost estimate** — measured walker traversal time on demo_app + Decimal + plug. Hard constraint: walker must not double oracle-build wall on Decimal-class projects. v1.5 picked tracer-only specifically to avoid compile-time walker cost; if the env walker can't beat that constraint, the design pivots (incremental walker, walker-on-demand for mutated modules only, etc.). A negative outcome here is a real result, not a failure.
6. **Mutator ordering for first implementation** — likely sequence: string body literals → atom body literals (with atom-table-pollution policy) → list/map/tuple body literals → pattern-position literals → variable mutators. Justified on equivalent-mutant rate and walker-complexity grounds.
7. **Go/no-go gate for v1.14 implementation** — concrete acceptance criteria: LOC estimate, target cold-compile overhead, byte-identity preservation for v1's existing dispatch-shaped mutants (env walker MUST NOT regress tracer oracle coverage), validation target set.

Acceptance: design doc committed; all seven questions answered concretely; cold-compile cost measured (not estimated); stable-ID migration policy explicit; go/no-go recommendation explicit. If go: v1.14 implementation milestone scope written into PLAN.md as a horizon item.

**Explicitly NOT in v1.13:**
- Any production code path for the env walker (M39 is a spike like M29/M32/M36).
- New mutators (M37 was the v1.12 catalog-growth closure).
- Pattern-mutator framework design (v2; M39 documents feasibility, doesn't design).
- `--fail-on-drift` for `mix mut.drift` (defer until requested).
- Persistent default flip, coverage default flip, affected-test selection, helper-process recompile isolation, reopening Ecto/Gettext/clustered-Mox persistent support, body-literal schema routing.

**v1.13 outcome (2026-05-11):** both milestones closed across 2 commits. M38 removed `MUT_PERSISTENT_COMPILE_MODE=helper_process` + `compile_via_helper_process/1` (M29 spike), `MUT_PERSISTENT_POOL_RESET=apps_restart` + `reset_pool_apps/0` (M36 spike), and narrowed `Persistent.port_env/1` forwarding back to `MUT_PERSISTENT_DIAG` only; rewrote the pre-M28 Mox boot-warning example text; added the `:supervisor_init` policy note distinguishing Ecto-class structural drift from low-rate plug-class drift; documented `mix mut.drift --json` schema with examples (stable for CI consumption from v1.13 forward, SemVer contract). M39 committed `docs/spikes/M39_env_walker.md` with **GO** for v1.14 first implementation: 11 public `Macro.Env` APIs identified (all stable ≥1.17, no Elixir floor bump), macro-expansion explicitly forbidden, stable-ID migration declared NOT required (env walker added as fifth candidate source consumed only by `Mut.Mutator.StringLiteral`), and throwaway-prototype cold-walk cost measured at 0.06% / 0.21% / 0.72% of oracle wall on demo_app / Decimal / plug (14× headroom against the 10% hard gate). First v1.14 mutator scoped narrowly: `Mut.Mutator.StringLiteral` only, fallback-routed, scope `:function_body`, context `nil`, trust `:trusted`. Defaults unchanged: `--worker-type mix`, `--selection static`.

### v1.14 (2 milestones — env walker first implementation)

M39 returned GO with measured cold-walk cost 14× under the hard gate. v1.14 ships the env walker as a fifth candidate source alongside `dispatch_candidates`, `guard_candidates`, `attribute_candidates`, and `body_literal_candidates`, plus `Mut.Mutator.StringLiteral` as the first env-walker-backed mutator. Both behind opt-in flags; defaults unchanged.

**Theme**: first env-walker implementation, narrow mutator surface, no stable-id migration. M39 declared no migration required; v1.14 acceptance enforces it via a byte-identity gate against pre-M40 plan output.

**Defaults do NOT change in v1.14.** `--worker-type mix`, `--selection static`, env walker disabled unless `--enable env_walker` / `--enable string_literal`.

Two milestones, mirroring M19's pattern: one large implementation milestone (~970 production LOC + ~450 test LOC per M39's estimate) with internal commit pacing, followed by one validation/decision milestone. Splitting into more granular milestones (foundation / classification / mutator / integration as separate shippables) fails the "independently shippable" test — env walker without a mutator and mutator without walker are both untestable.

**M40 — Env walker + StringLiteral mutator (foundation through integration).** Ships `Mut.EnvSnapshot`, `Mut.OpaquePolicy`, `Mut.EnvWalker`, `Mut.EnvOracle`, defguard/`if`/`unless` trusted-only-with-tracer-proof logic, `Mut.Mutator.StringLiteral`, diagnostics + metrics, and opt-in CLI flags. Seven internal commits: data types, walker skeleton, oracle + orchestrator hook (disabled), trusted-form logic, the mutator itself (fallback-routed; non-empty → `""`; empty / interpolated → skip per M39's deferral), diagnostics + reporter integration, public flags + CHANGELOG.

Acceptance gates (whole milestone):
- **Byte-identity gate**: existing dispatch / guard / attribute / body-literal stable IDs unchanged on demo_app, plug_crypto, Decimal, plug. Env walker MUST NOT regress tracer-oracle coverage. Verified via stable-id diff harness.
- **No-expansion gate**: automated grep over env-walker code paths for forbidden APIs (`Macro.expand`, `Macro.expand_once`, `Code.eval_*`, `Code.compile_*`, `Kernel.ParallelCompiler`, `:elixir_expand`, `:elixir_module`, `:elixir_def`, `Macro.Env.expand_import`, `Macro.Env.expand_require`, `Macro.Env.define_import`, `Macro.Env.fetch_alias`, `Macro.Env.fetch_macro_alias`). M39 enumerated these; M40 wires the grep as a verify layer.
- **Cold-compile gate**: `parse_ms + walk_ms ≤ 10% of oracle_build_ms` on Decimal and plug. M39's prototype measured 0.21% / 0.72%; production has 14× headroom but the regression bar stays at 10%.
- **Opt-in default**: env walker disabled unless `--enable env_walker` / `--enable string_literal`. Default `bin/verify` does not exercise the walker.
- **No regression of existing mutators**: Decimal integer-literal + boolean-literal + body-literal kill counts unchanged; demo_app fixture stable IDs unchanged.
- All 9 `bin/verify` layers green.

Subagent brief: M39's design doc at `docs/spikes/M39_env_walker.md` is binding (no deviation from the 11 public APIs without explicit re-design); use `~/elixir_sense/lib/elixir_sense/core/compiler.ex` as reference for AST traversal (strip to context-only, do not collect symbol-table metadata); do NOT migrate any existing `Mut.AstWalk` walker behind `EnvWalker` (v1.15+ work); fallback-route only (schema routing is a separate stable-id migration decision).

**M41 — Real-target validation + StringLiteral default decision.** Mirrors M24 / M25's matrix-then-decide shape. Validation matrix: demo_app (fixture proof), plug_crypto (small dispatch-heavy baseline), Decimal (byte-identity stress), plug (M34-unblocked, supervisor-init class), phoenix_html (M34-unblocked macro-heavy target — primary opaque-policy stress; gettext available as secondary `--worker-type mix` informational target if budget allows).

Measure per target: new string mutants surfaced, kill/survived/error/invalid counts, env-walker parse + walk time, stable-ID diff for existing mutants (MUST be zero), skip-reason histogram, mutant-run wall delta. Side validations (same data, no new bench cycles): env walker × persistent worker interaction; opaque-policy false-positive/negative rate; skip-reason distribution informing v1.15+ walker hardening.

Decision output at `docs/decisions/M41_string_literal_decision.md`:
1. **Default policy**: `keep_opt_in` (if invalid rate ≥10% on any target OR opaque-policy false negatives detected), `expand_table` (if equivalent rate <20% AND kill rate ≥60% — candidates: `non-empty → "x"`, `non-empty → " " + s`), or `defer_further` (if matrix surfaces unknown invalid class — revert to opt-in-experimental and re-spike in v1.15).
2. **Interpolated-string disposition**: record matrix-surfaced demand; scope v1.15 milestone if demand exists.

Acceptance: zero stable-ID churn for existing mutants on all 5 targets; parse + walk gate holds in production on Decimal and plug; no-expansion grep gate holds; decision doc committed; BENCHMARKS.md v1.14 section; persistent-worker guide updated with any env-walker interaction findings.

**Explicitly NOT in v1.14:**
- Schema routing for any env-walker mutator (fallback-routed exclusively; schema migration is v1.15+ if ever).
- Migrating existing `Mut.AstWalk` walkers behind `EnvWalker` (M39 forbids in v1.14; v1.15+ has its own byte-identity gate).
- New mutators beyond StringLiteral (float / atom / list / map / tuple / pattern-position / variable all deferred to v1.15+ per M39 ordering).
- Atom-table pollution policy (v1.15+ design item for atom-literal mutator).
- Interpolated-string mutation (M39 deferred until source-span replacement proven safe; M41 records demand if any).
- Persistent default flip, coverage default flip, affected-test selection, helper-process recompile isolation, reopening Ecto/Gettext/clustered-Mox persistent support.
- Stable-ID input changes (M39 declared none required; reopen only if a future mutator forces one).
- New CLI flags beyond `--enable env_walker` and `--enable string_literal`.

### v1.15 (5 milestones — prune worker types + grow env-walker literals)

v1.7–v1.12 invested five-plus milestones (M18–M22, M28–M36) in the persistent worker. The default-flip gate closed *structurally* in v1.11 and never reopened: whole project classes (Ecto, Gettext, clustered Mox, pooled HTTP clients) drift under persistent in ways reset hooks provably cannot fix (M30/M36), and on the targets that matter persistent is slower than `mix` (BENCHMARKS: 1.5× slower on Decimal, 0.59× on plug_crypto at c=4). It only wins on demo_app and a couple of friendly libraries. Meanwhile the subsystem (~3,250 LOC across `persistent*`, the drift bucketer, the boot-warning detector, and `mix mut.drift`) taxes every other workstream: each new mutator has to be byte-identity-validated under *both* worker types. v1.15's theme is to **delete that tax and reinvest the freed validation budget into the env-walker mutator catalogue.**

This is a pruning-plus-focused-expansion release, not infrastructure. The env walker (v1.14) and coverage selection (v1.5) stay; only the persistent worker leaves.

**Default `--worker-type` is removed, not flipped.** `mix` becomes the only worker. `--worker-type mix` is accepted for one release as a deprecated no-op (warns once); `--worker-type persistent` errors with a CHANGELOG pointer.

**Default `--selection` does NOT flip in v1.15.** Coverage stays opt-in. Coverage selection is far less invasive than worker types and useful diagnostically; it is kept, just not promoted.

**New mutators ship opt-in.** No new mutator is default-on in v1.15; M46 decides defaults from execution data. Elixir floor stays `>= 1.19.0`.

**M42 — Worker-type removal + model/doc simplification.** Delete `lib/mut/worker/persistent*`, `persistent_runner/{reset,diag}`, `persistent/detector`, the `drift/bucketer*` modules, and `mix mut.drift` (all exist only to triage mix-vs-persistent divergence). Strip the `--worker-type` branch from `cli`, `mut`, `worker`; keep `--worker-type mix` as a deprecated warn-once no-op and reject `persistent`. Remove the `e2e_persistent` `bin/verify` layer, persistent blocks from `metrics` / `reporter.terminal` / `reporter.stryker_json`, and persistent references in `application` / `runtime` / `schema_placer` / `recompile` / `mut.e2e`. Delete `docs/PERSISTENT_WORKER_GUIDE.md` and prune the now-moot mix-only catalogue / structural-drift prose (keep the SchemaPlacer escaped-quote note — that bug hit both worker types). Bring README/CHANGELOG/BENCHMARKS in line with the simpler model (the README still claims sequential/static/no-literals, all stale since v1.5/v1.9/v1.14). Acceptance: remaining `bin/verify` layers green; demo_app / plug_crypto / Decimal stable-id sets and kill counts byte-identical to v1.14 `mix`-worker runs; no `persistent`/`worker_type` symbols remain in `lib/`.

**M43 — EnvWalker consolidation (byte-identity gated). ⚠️ designated release valve.** M40 deferred this here. Migrate `dispatch_candidates`, `guard_candidates`, `attribute_candidates`, and `body_literal_candidates` to consume `EnvWalker` context instead of their standalone `AstWalk` traversals, so `EnvWalker` stops being a parallel fifth source and becomes *the* walker. Pure refactor; no user-visible payoff beyond reduced duplication, and the only milestone with real regression surface. Hard gate: stable IDs byte-identical for every existing mutator on demo_app, plug_crypto, Decimal, plug — any churn stops the migration. No-expansion grep gate (M40) extended to migrated paths. If the release runs long, M43 slips to v1.16 at zero downstream cost — the M44/M45 mutators work fine against the parallel fifth-source EnvWalker as-is.

**M44 — Low-noise literal expansion: Float + Nil + StringLiteral table.** `Mut.Mutator.FloatLiteral` (`0.0→1.0`, finite `f→0.0`/`f+1.0` with equivalent filters) and `Mut.Mutator.NilLiteral` (`nil`↔ a sentinel, body-position only) — the two lowest-noise next literals per M39 ordering. Plus `StringLiteral` `expand_table`: add `non-empty→"x"` and prepend-space replacements (interpolated-string handling only if M41/validation surfaced demand). All env-walker, fallback-routed, opt-in. Hard gate: zero stable-id churn for existing mutants on the corpus.

**M45 — Higher-noise literals: Atom + Collection. ⚠️ second release valve, gated.** `Mut.Mutator.AtomLiteral` with a **strict no-new-atoms allowlist** (closed replacement set, e.g. `:ok ↔ :error`; never synthesize atoms; `true`/`false` excluded — already handled by BooleanLiteral) — the atom-table-pollution policy M39 flagged as a v1.15 design item, designed before any code. `Mut.Mutator.CollectionEmpty` (body-position list/map/tuple → empty, skip already-empty and pattern positions). These carry the highest equivalent/invalid risk in the release; if M44's validation surfaces an unknown invalid class, M45 defers to v1.16. Env-walker, fallback-routed, opt-in.

**M46 — Literal execution validation + default decisions.** v1.14 left StringLiteral on plan-level evidence only; v1.15 runs *all* opt-in literals (string/float/nil/atom/collection) end-to-end on the acceptance corpus — demo_app, plug_crypto, Decimal, plug, phoenix_html (macro-heavy opaque-policy stress). Measure per target: new mutants surfaced, kill/survived/error/**invalid** counts, equivalent-ish survivors, env-walker parse+walk time, stable-id diff (must be zero for existing). Decision docs at `docs/decisions/M46_*.md`: per mutator, keep-opt-in vs default-on vs fold into a named `--enable literal` preset, using the M25/M41 thresholds (kill ≥60%, equivalent <20%, invalid <10%). Acceptance: decision docs committed; BENCHMARKS v1.15 section; zero stable-id churn for existing mutants on all five targets.

**Explicitly NOT in v1.15:**
- Coverage default flip (kept opt-in; less invasive than worker types, useful diagnostically).
- Schema routing for any env-walker mutator (fallback-only persists; schema migration is a separate stable-id migration if ever).
- Pattern-position literal mutators and variable mutators (v1.16+/v2 per M39 ordering; need invalid/equivalent data M46 starts gathering).
- Function-call deletion and return-value replacement (deferred indefinitely; high false-positive risk).
- Persistent worker in any form — it is removed, not deprecated-in-place.
- Stable-id input changes; cross-run history; wrapper guard schemata.

**v1.15 outcome (2026-05-23):** all five milestones resolved across commits `8bbe479..e12c5cd`. M42 removed the persistent worker (~5,000 LOC deleted, ~125 added); `mix` is the only worker, `--worker-type mix` is a deprecated warn-once no-op, `persistent` is rejected. M43 was **slipped to v1.16** via its release valve — a pre-implementation spike against real plan data proved the byte-identity gate cannot be met by making `EnvWalker` the single source (incompatible `ast_path` encodings: `EnvWalker` emits `[]` and keys on byte spans; `AstWalk` uses positional paths), so the redesign must instead be *AstWalk absorbs EnvWalker's trust/context*. M44 shipped FloatLiteral, NilLiteral, and a StringLiteral table expansion (all opt-in, byte-identity verified on 5 targets). M45 shipped AtomLiteral (closed allowlist) and CollectionEmpty (lists + 2-tuples only; maps + n-tuples slipped to v1.16). M46's execution-level validation surfaced and fixed a latent `literal_span` bug (scalar spans were ~1 char → invalid mutants; the fix intentionally churned String/Atom/Nil opt-in stable IDs as a one-time migration) and decided defaults: **AtomLiteral `default_on`** (only literal clearing the per-target-minimum threshold rule), the other four `keep_opt_in`. Defaults unchanged at ship: `--selection static`, env walker opt-in.

### v1.16 (5 milestones — default-policy + literal-reporting robustness)

v1.15 ended a removal-plus-expansion arc and left a small, well-characterized backlog. v1.16's theme is **harvest + harden**: deliver the one decided-but-undelivered default (AtomLiteral), fix the literal-reporting robustness bug M46 surfaced, trim the noisiest literal row, close the collection-shape gap — and explicitly *not* force the M43 consolidation refactor, whose ROI is unproven (M39 measured env-walker cold-walk cost at <1% of oracle wall, so the parallel design carries no meaningful tax).

This is a default-policy and robustness release, not a broad catalog push. No genuinely new mutator type ships; the only catalog change is closing CollectionEmpty's deferred shapes.

**Defaults DO change in v1.16 — once, additively.** AtomLiteral becomes default-on (M46 decision). This is the first env-walker mutator in the default plan. The change is additive: existing stable IDs are unchanged; new AtomLiteral mutants are added. The other four env-walker literals (String/Float/Nil/Collection) stay opt-in. `--selection static` and coverage-opt-in are unchanged.

**M47 — Literal-reporting robustness.** Fix the M46-surfaced bug: `Mut.Reporter.StrykerJson.files/3` raised `TokenMissingError` rendering one plug mutant's diff and aborted the entire JSON write *after* all 1,390 mutants had run — a full run's results lost at the reporting step. Guard diff rendering so a single un-renderable mutant degrades gracefully (skip-with-marker) instead of crashing the report; apply the same guard to the terminal reporter. Acceptance: a fixture mutant with escape-trap diff content renders or degrades without aborting; the plug v1.19.1 literal run writes valid JSON.

**M48 — AtomLiteral default-on + mutator default-tier flag model.** The substance is the flag architecture, not a boolean. Today `:env_walker` is an all-or-nothing `enabled_targets` entry — adding it to the default set would silently activate String/Float/Nil/Collection too. M48 introduces per-mutator granularity within the env-walker source and a clean tier split: **default-on set / opt-in set / named presets**. Make AtomLiteral default-on (env walker runs by default, but only AtomLiteral is active by default); keep the other four `--enable`-only; preserve every existing `--enable` flag. Acceptance: default `mix mut` plan includes AtomLiteral mutants and excludes String/Float/Nil/Collection; all non-env-walker stable IDs byte-identical; `--enable string_literal` etc. still work; the M46 span behavior is preserved.

**M49 — StringLiteral table trim.** Remove the equivalent-heavy prepend-space row (`s → " " <> s`; M46 flagged it as kill-rate-dragging, especially on Decimal). Keep `s → ""` and `s → "x"` opt-in. Removing a replacement deletes those mutants; the remaining rows' stable IDs must be unchanged (identity keys on span + replacement). Acceptance: prepend-space mutants absent from plans; remaining StringLiteral IDs unchanged on the corpus; golden lists updated.

**M50 — CollectionEmpty maps + n-tuples (gated; release valve).** Close M45's deferred shapes: map `%{...} → %{}` (with strict struct-map `%S{}` exclusion) and n-tuple `{a, b, c} → {}`. These are unwrapped AST nodes (`{:%{}, …}`, `{:{}, …}`) needing a separate walk pass beyond the `literal_encoder`-wrapped shapes M45 handled. Hard gates: byte-identity for existing mutants; per-mutator invalid rate <10%; struct maps never emptied (verified by fixture). Release valve: if struct exclusion or shape noise can't be made clean, ship only the design note and defer to v1.17.

**M51 — EnvWalker consolidation design + proof (spike; cuttable).** Per the harvest theme, do *not* implement M43's migration. Extend `docs/decisions/M43_envwalker_consolidation.md` into a concrete redesign (AstWalk absorbs EnvWalker's trust/context classification into its frame traversal, keeping AstWalk's path encoding) plus a *tiny* proof that trust/context can attach to AstWalk frames without stable-id churn. No migration code ships. Output: updated decision doc + explicit go/no-go for a v1.17 implementation milestone. Cut first if budget tightens; M50 does not depend on it (M45 confirmed maps/tuples are doable as a standalone walk pass).

**Explicitly NOT in v1.16:**
- M43 consolidation *implementation* (design/proof only via M51; migration is v1.17+ if proven worth it).
- Pattern-position literal mutators and variable mutators (still gated on the richer v2 env walker).
- Schema routing for any env-walker mutator; the `--enable literal` preset (needs ≥2 default-on candidates; only AtomLiteral qualifies).
- Coverage default flip; function-call deletion / return-value replacement; cross-run history; stable-id input changes (beyond M46's already-shipped one-time span migration).

**v1.16 outcome (2026-05-23):** all five milestones shipped (`9bbd205..f3d709f`). M47 made `Mut.Reporter.StrykerJson` degrade gracefully (unformatted render → marker) instead of aborting the whole JSON write on one un-renderable diff — the plug run now writes valid JSON end-to-end. M48 added a mutator tier model (`Defaults.default_on/0` + `opt_in/0`) and made AtomLiteral default-on without leaking String/Float/Nil/Collection into the default plan (byte-identity verified on all four named targets; non-env IDs identical). M49 dropped the equivalent-heavy StringLiteral prepend-space row. M50 closed CollectionEmpty maps + n-tuples with strict struct-map exclusion (0% invalid on plug_crypto + Decimal). M51's spike returned **feasible, DEFER** for the consolidation (no perf payoff; dedup-only vs byte-identity risk). v1.16 is the first release to change the default plan (AtomLiteral default-on, additive).

### v1.17 (4 milestones — literals first-class + v2 mutation surface)

v1.13–v1.16 were env-walker plumbing plus incremental literal additions. v1.17 is the first genuinely ambitious surface-and-performance release since v1: it makes the literal catalogue **fast** (schema-routing) and **broader** (pattern-position + variable mutators — the v2 shapes promised since v1.5), then validates the whole thing on a real OSS corpus. This is v2-scale work delivered as a single large release.

Two findings de-risk and reshape the v1.5-era plan:
- The env walker **already classifies `:match` (pattern) context** (`EnvSnapshot.context :: nil | :match | :guard`); the current mutator gate just hard-requires `context == nil`. Pattern-position literals are largely a gate relaxation plus hazard rules, not new walker infrastructure.
- The persistent worker is gone (v1.15), so the old "mix-only drift" OSS targets (ecto, gettext, phoenix) now simply run under the single `mix` worker — broad OSS validation is finally cheap. `../elixir_oss/projects` holds 33 pinned real projects.

**Defaults: no new default-on flips beyond M46's AtomLiteral.** New surface mutators (pattern-position, variable) ship opt-in; M55 decides graduations from execution data. `--selection static` and coverage-opt-in unchanged. The literal schema-id migration (M52) is an explicit one-time stable-id change for the env-walker literals only — gated and documented.

**Prelude (not a milestone):** README + BENCHMARKS v1.16 closure (README still claims atoms opt-in / collections list-only; BENCHMARKS has no v1.16 section). Ships as the first commit.

**M52 — Schema-route the literal catalogue (reconcile + stable-id migration).** The performance workstream. Reconcile the `literal_encoder` AST (literals wrapped in `{:__block__, …}`, byte-span identity, `ast_path = []`) with `Mut.SchemaPlacer` (plain AST, `ast_path_hash`-keyed case-gate placement) so env-walker literals can bake into one instrumented schema build instead of per-mutant fallback recompile. Carries an explicit one-time literal stable-id migration (the env-literal identity changes; non-literal IDs MUST NOT). Literals that cannot be schema-placed fall back as today. Acceptance: literal mutants execute via the schema build; non-env stable IDs byte-identical on the corpus; documented before/after fallback-vs-schema wall-clock on Decimal + plug; invalid rate unchanged.

**M53 — Pattern-position literal mutators.** Relax the mutator gate from `context == nil` to also admit `context == :match` for a conservative literal subset (integer / atom / boolean / nil / string), fallback-routed. Hazard rules: never mutate a pinned variable's matched literal into an overlapping/unreachable clause; skip positions where the swap would make two clauses collide; strict invalid + equivalent gating. Acceptance: zero stable-id churn for existing mutants; per-mutator invalid < 10% on the corpus; pattern mutants fire on real `:match` positions; opt-in.

**M54 — Variable mutators (walker binding-scope extension + mutators).** The infra-heavy surface item, committed in full. Extend `Mut.EnvWalker` with local variable binding-scope tracking (which names are bound and in scope at a node — distinct from the alias/import/require maps it tracks today). Add conservative opt-in variable mutators (e.g. replace an in-scope variable reference with another in-scope variable; replace with a literal where types permit), heavily gated against the noise profile. Internal commit pacing: binding-scope tracking → snapshot wiring → mutators → gating + diagnostics. Acceptance: binding-scope tracking adds no stable-id churn for existing mutants; variable mutants are opt-in; invalid + equivalent rates tracked and reported; no-expansion grep gate holds on the extended walker.

**M55 — Broad OSS validation matrix + combined decisions.** Run the full v1.17 catalogue across a curated ~10-project subset of `../elixir_oss/projects` (decimal, jason, plug, gettext, ecto, credo, req, timex, makeup, oban — spread across math/pure-lib, dispatch-heavy, macro-heavy, pattern/literal-rich) under the single `mix` worker. Pin SHAs. Per target × mutator: kill / survived / error / **invalid** / equivalent-ish counts, schema-vs-fallback wall-clock, stable-id diff (zero for existing), skip-reason histogram. Decisions in `docs/decisions/M55_*.md`: pattern-position and variable default policy (keep_opt_in / default_on / preset), and the schema-routing perf verdict (did M52 materially reduce literal wall-clock?). Acceptance: decision docs committed; BENCHMARKS v1.17 matrix; zero stable-id churn for existing mutants across the corpus; `bin/verify` green.

**Explicitly NOT in v1.17:**
- Schema routing for non-literal mutators (M52 is literals only; dispatch/guard/attribute stay as-is).
- New literal *shapes* beyond the existing catalogue (the surface growth is pattern-position and variable, not new value types).
- Function-call deletion / return-value replacement (deferred indefinitely).
- Coverage default flip; cross-run history; wrapper guard schemata.
- EnvWalker consolidation implementation (M51 deferred it; reopen only on a maintenance trigger).

**v1.17 outcome (2026-05-25):** all four milestones + the doc prelude shipped (`bf14d68..f6fb850`, ~13 commits). M52 schema-routed the scalar-literal catalogue (unplaceable bitstring/clause-head literals reroute to fallback; one-time literal stable-id migration); the perf verdict confirmed it (one shared schema build vs per-mutant recompile, ~0.4–2.1 s/mutant saved). M53 shipped pattern-position literal mutators (opt-in `:pattern_literal`). M54 shipped variable mutators + walker binding-scope tracking (opt-in `:variable`); VariableToLiteral was deferred then landed in M56 with syntactic use-site type hints (opt-in via `--mutators` only, not `--enable variable`). M55 validated a 7/10 OSS subset and decided **all new surfaces keep_opt_in** (variable mutation errors on 27% of gettext / 6% of plug — codegen-heavy false-positive-shaped detections; pattern-literals are the cleaner future graduation candidate). Validation caught and fixed **four AST-shape false-positive classes** (bitstring type specs, `\\` defaults, pipe-rhs/captures) plus a fallback-recompile engine bug (credo false-invalids; root cause: no `Mix.start` in the recompile eval). Left open: variable error-tail on macro-heavy code, the credo residual (10.3%), an incomplete matrix with no equivalent-rate data, and three env-blocked targets (timex/req/oban).

### v1.18 (5 milestones — defaults grow up: harden, then graduate)

v1.17 shipped a large new mutation surface but left it noisy, opt-in, and undecided. v1.18's theme is **maturation**: pay down the v1.17 surface debt (the hardening spine), then flip the two long-deferred defaults the spine's data unlocks — clean-surface graduation and coverage-as-default. No new mutation surface; no new big subsystem. Incremental cross-run history is explicitly held for a later release.

**Two defaults change in v1.18, both data-gated.** The clean opt-in surfaces graduate to default-on (M60), and `--selection` flips from `static` to `coverage_with_static_fallback` (M61) — the staged flip the v1.5 HLD always planned as a post-validation follow-up. Both are gated on the M59 matrix + equivalent-rate data; neither flips on assertion. Elixir floor stays `>= 1.19.0`.

The spine (M57–M59) ships regardless; the graduations (M60–M61) ship only what the data clears.

**M57 — Variable-mutator noise refinement + identifier-classification hardening.** Cut the v1.17 error tail so variable mutants become graduation-eligible: skip codegen / macro-definition modules, and gate `VariableReplace` swaps on the swapped-out variable having other uses (avoid unused-variable churn) — both flagged by M55. Consolidate the four reactive false-positive fixes (bitstring type specs, `\\` defaults, pipe-rhs, `&`-captures) into one principled "is this identifier a real variable read/binding" classifier in `Mut.EnvWalker`, so the next AST shape doesn't need a fresh patch. Acceptance: variable error rate materially down on gettext/plug; zero regressions on the four known false-positive shapes (regression-tested); no stable-id churn for existing mutants.

**M58 — Fallback-recompile engine hardening.** Confirm or close the credo residual (10.3% invalid): determine whether it is genuine for/unquote metaprogramming or still-engine (compile-time-dependent staleness after single-file recompile, or parallel-worker sandbox contention). Harden `Mut.Recompile`/sandbox for compile-time-registration projects (`use Macro`-shaped). Broad impact — fallback underpins guards, attributes, pattern-literals, and variable mutators. Acceptance: credo invalid rate explained (genuine vs fixed); a `use`-macro-registration fixture recompiles correctly under fallback; no regression on the M55 clean targets.

**M59 — Complete the OSS matrix + equivalent-rate characterization.** The data milestone both graduations depend on. Wire the six unwired targets (ecto, credo, req, timex, makeup, oban) into `bench/run.sh`; unblock what is fixable and document the genuinely env-blocked (timex µs-precision test drift, req ezstd native build, oban multi-DB infra). Add per-mutator **equivalent-rate** measurement — the metric M55 lacked for graduation decisions. Acceptance: matrix runs to ≥8/10 with documented blockers; equivalent-rate reported per mutator per target; BENCHMARKS v1.18 matrix section.

**M60 — Surface graduation (first default-on flips since M46).** Using M59 data, flip the surfaces that clear the M25/M41 per-target-minimum rule (kill ≥60%, equivalent <20%, invalid <10%) to default-on — pattern-position literals first (M55's identified clean candidate), refined `VariableReplace` only if M57's refinement brings it over the bar. Decision docs per surface. Acceptance: graduated surfaces in the default-on tier; non-graduated stay opt-in; default-plan stable-id change is additive only (existing IDs unchanged); decision docs committed.

**M61 — Coverage-as-default + selection sharpening.** Validate coverage selection across the M59 matrix (interaction with the now-default-on surface; the persistent-worker removal simplifies this), then flip `--selection` default from `static` to `coverage_with_static_fallback` (the safe mode that falls back to static when coverage is pathological — never bare `coverage`). Sharpen per-mutant test ordering/selection only where the data shows fanout wins. Acceptance: coverage default validated on the matrix with no kill-count regression vs static; `--selection static` remains available as the escape hatch; selection-mode reported in every run; decision doc + perf delta in BENCHMARKS.

**Explicitly NOT in v1.18:**
- Incremental cross-run history (held for a later release; the big untouched v2 perf bet).
- New mutation surface or new literal value shapes (v1.18 grows defaults, not the catalogue).
- Schema routing for non-literal mutators; wrapper guard schemata.
- Function-call deletion / return-value replacement (deferred indefinitely).
- EnvWalker consolidation implementation (still maintenance-trigger gated).
- Bare `--selection coverage` as default (only `coverage_with_static_fallback`).

**v1.18 outcome (2026-05-25):** all five milestones shipped (8 commits). The spine landed: M57 cut the variable error tail (gettext 211→45, plug 202→24) and consolidated the four false-positive fixes into one read-side classifier; M58 closed the credo invalid residual (~40% → 3.3%) by root-causing the fallback-recompile engine; M59 took the matrix to 8/10 (req/oban env-blocked; timex unblocked via a documented µs-drift exclusion) and added per-mutator equivalent-rate tooling. Then both graduations came back **data-gated no-flips**: M60 graduated nothing (no surface clears <20% equivalent on every target — VariableReplace 22–39%, pattern literals 21–33%; IntegerLiteral-in-pattern flagged as closest, failing ecto only at 21.1%), and M61 did not flip coverage-as-default (collection *crashed the run* on 3/8 targets). The honest result: hardening worked, the data said neither default is ready, both stayed put with documented evidence rather than flipping on assertion.

### v1.19 (4 milestones — finish the stalled flips)

v1.18 hardened the surface but shipped no flips. v1.19 converts both v1.18 stalls into real outcomes — not by asserting readiness, but by fixing the two root causes that blocked the data from supporting a flip: an equivalent-rate metric that over-estimates, and a coverage runner that aborts instead of degrading. Two independent tracks; the graduation track ships only what the sharpened data clears, the coverage track lands a flip the per-file fallback makes safe.

**Defaults may change in v1.19, both still data-gated.** Surfaces that clear the (sharpened) gate graduate to default-on (M63); `--selection` flips to `coverage_with_static_fallback` once per-file fallback makes it crash-safe (M65). If the sharpened data still doesn't support a graduation, M63 ships nothing — same discipline as M60. No new mutation surface, no new subsystem. Incremental cross-run history remains held. Elixir floor stays `>= 1.19.0`.

**M62 — Sharper equivalent estimation + gate-rule revisit.** The M60 gate used a covered-survivor heuristic the decision doc itself calls an over-estimate (it counts every survivor on a covered line as possibly-equivalent, conflating a weak test with a truly-equivalent mutant). Two complementary fixes: (1) tighten the estimate — exclude uncovered survivors from the equivalent count, and add cheap syntactic equivalence rules where they exist, producing a defensible lower-bound rather than an inflated upper-bound; (2) revisit the graduation gate rule itself given the metric's known bias — e.g. admit a single-target miss within a small margin (≤~2pp) when the estimate is an acknowledged over-count. Both changes are documented and justified, since they change graduation outcomes. Acceptance: a defensible equivalent estimate (or explicit lower-bound) + a documented gate rule; the M59 matrix graduation table recomputed under the new metric/rule.

**M63 — Graduate what clears.** Apply M62's sharpened metric and rule to the surfaces. IntegerLiteral-in-pattern is the prime candidate (one margin-point from clearing under the over-estimate); re-evaluate the other pattern literals and refined VariableReplace. Flip whatever clears into the `default_on` tier; the rest stay opt-in. Data-gated like M60 — ships nothing if nothing clears. Acceptance: default-plan stable-id change is additive only (existing IDs unchanged); per-surface decision docs with the recomputed numbers; `bin/verify` green.

**M64 — Per-file crash-tolerant static fallback in the coverage runner.** Make `coverage_with_static_fallback` live up to its name granularly: when coverage collection for a test file fails — by exception (gettext: `ParallelCompiler` under `:cover` on compile-in-test), by timeout (credo: `:cover` overhead blows the per-file deadline), or by BEAM/JIT crash (timex: `:cover` + hot code-load) — that file's tests fall back to static selection and the run continues. The hot-codeload crash needs per-unit isolation so a single file's BEAM crash is recoverable, not run-fatal. Acceptance: on gettext/credo/timex, coverage no longer aborts the run; failing units degrade to static and are reported as such; the run completes with a per-file coverage/static mix surfaced in metrics.

**M65 — Flip `--selection` default to `coverage_with_static_fallback`.** Re-validate across the M59 matrix now that M64 makes the three failers degrade gracefully; confirm kill counts match `static` (selection narrows test work, not outcomes); flip the default. `--selection static` stays the documented escape hatch and the only fully-portable mode; active mode is reported per run. Never bare `coverage`. Acceptance: coverage default validated on the matrix with zero kill-count regression vs static; `static` still works; decision doc + per-target fanout/wall-clock delta in BENCHMARKS.

**Explicitly NOT in v1.19:**
- Incremental cross-run history (still held).
- New mutation surface or new literal value shapes.
- Schema routing for non-literal mutators; wrapper guard schemata.
- Function-call deletion / return-value replacement (deferred indefinitely).
- EnvWalker consolidation implementation (maintenance-trigger gated).
- Bare `--selection coverage` as default; coverage caching (v2).
- Exact equivalent-mutant detection (undecidable in general; M62 sharpens the estimate, it does not claim exactness).

**v1.19 outcome (2026-05-25):** all four milestones shipped (7 commits); unlike v1.18, **both flips landed**. M62 reframed the equivalent metric as an explicit upper bound and revised the gate to admit a single-target ≤2pp miss (justified by the upward bias); the recomputed table cleared IntegerLiteral-in-pattern. M63 graduated IntegerLiteral-in-pattern to default-on — the first default-on flip since M46 — additive-only (demo_app byte-identical, Decimal +18, existing IDs untouched). M64 made the coverage runner degrade per-file (records degraded files, unions their static coverage to avoid false survivors); gettext, which aborted under coverage in M61, now degrades `backend_test` and completes. M65 flipped `--selection` default to `coverage_with_static_fallback` with validated kill-count parity (a 1-mutant run-1 diff proved to be test flakiness, killed on re-run); `static` stays the portable escape hatch.

### v1.20 (6 milestones — umbrella support + catalogue growth)

v1.20 takes on the engine's biggest untouched capability and grows the mutator catalogue at the same time. Two of the project's standing limits fall here: mutalisk has **refused umbrella projects since v1** (`assert_not_umbrella!` hard-raises), and the catalogue has stayed dispatch/literal/variable-shaped. v1.20 adds umbrella support (validated on a real umbrella) plus two new mutator families.

Real-world drivers: `~/unilink` (5-app umbrella) and `~/zorbito` (14-app crypto/clustering umbrella). **Validation scope is unilink only this release;** zorbito (whose 14-app suite likely needs DB/clustering infra — the oban/req blocker class) defers to v1.21.

**Umbrella support is the dominant bet and touches nearly every phase:** working-copy materialization (umbrella root + `apps/`), the overlay (replace the not-umbrella raise; handle `apps_path`), the Build-Path Contract (per-app ebins under the umbrella build root), oracle/schema builds across all apps, the sandbox, test selection, and — the hard correctness piece — **fallback recompile with cross-app compile dependents** (mutating app A recompiles dependent app B). Given the unknowns, it leads with a design spike (project's spike-first culture: M18/M29/M36/M39/M51).

**Defaults:** the two new mutator families ship opt-in; M71 decides graduation from validation data (no new default-on flip is pre-committed). Umbrella support is automatic when the target is an umbrella (the prior hard-raise becomes real handling). Elixir floor stays `>= 1.19.0`.

Six milestones, two independent tracks. Umbrella: M66 → M67 → M68 (strict). Catalogue: M69, M70 (independent of umbrella; M70 is the designated release valve). Validation: M71 (needs both tracks). If umbrella runs long, M70 (pattern-shape, the noisiest/newest) cuts to v1.21 at zero downstream cost.

**M66 — Umbrella support design spike.** Design the umbrella model: work-copy + overlay for `apps_path` projects, the umbrella Build-Path Contract extension (per-app ebins, shared `_build/mut_*` root, `MIX_DEPS_PATH`), how the oracle/schema/fallback/sandbox phases change, and especially the **cross-app compile-dependency model** (the manifest walk must span apps so a mutant in app A recompiles dependents in app B). Throwaway proof on unilink to measure compile/oracle cost across 5 apps. Output: design doc at `docs/spikes/M66_umbrella.md` + explicit go/no-go and a v1.20 implementation scope. No production code beyond the throwaway proof.

**M67 — Umbrella oracle + schema build.** Implement the spike's design through the schema build: materialize an umbrella work copy, install the umbrella overlay (no longer raising), compile every app under the tracer for the oracle, place schemata across apps, and build the instrumented umbrella under the umbrella build-path role. Sandbox creation becomes umbrella-aware. Acceptance: unilink oracle + schema build succeed; per-app plans produced; non-umbrella single-app behavior byte-identical (the umbrella path must not regress the single-app path).

**M68 — Umbrella fallback + cross-app dependents.** The hard correctness piece: per-app Mix manifests, a dependency walk that spans app boundaries, and a fallback recompile that rebuilds the mutated app plus its cross-app compile dependents inside the sandbox before the targeted test run. Acceptance: a unilink fallback mutant in a depended-upon app recompiles its dependents correctly; sandbox reset restores all affected apps' artifacts; no false-invalids from stale cross-app state.

**M69 — Operator-expansion mutators.** Low-noise, schema-routed dispatch mutators extending the proven path: list/binary concat (`++` ↔ `--`, `<>`), bitwise (`band`/`bor`/`bxor`/`bsl`/`bsr` swaps), membership (`in` ↔ `not in`). Each carries `compatible?/2` for the matcher and an equivalence filter. Opt-in. Acceptance: per-mutator unit tests + fixture golden lists; zero stable-id churn for existing mutants.

**M70 — Pattern-shape mutator framework (release valve).** The deferred v2 item never built: pattern *shape* mutations (not just literals-in-patterns) — `_` ↔ named var, pin/unpin (`^x`). Tuple/list arity stays skipped (M39: too many non-viable mutants). Needs the conservative framework M39 sketched, with strict invalid/equivalent gating. Opt-in, fallback-routed. Highest noise/invalid risk in the release — cut to v1.21 if budget tightens. Acceptance: per-mutator unit tests; invalid rate measured and gated; zero stable-id churn for existing mutants.

**M71 — Umbrella (unilink) + new-mutator validation + decisions.** Validate umbrella support end-to-end on unilink (full `mix mut` run: oracle → schema → workers → fallback → report, per-app + aggregate score). Run the M69/M70 mutators on unilink + the OSS matrix; capture kill/invalid/equivalent rates. Decisions in `docs/decisions/M71_*.md`: operator-expansion and pattern-shape default policy (keep_opt_in / graduate, per the M62 sharpened gate); umbrella acceptance verdict. zorbito run as informational only if budget allows; infra blockers documented, not gating. Acceptance: unilink umbrella run completes with a valid report; new-mutator decisions committed; BENCHMARKS v1.20 section; zero stable-id churn for existing single-app mutants.

**v1.20 outcome (2026-05-25):** umbrella support shipped and validated; M70 cut to v1.21 per its release valve. The umbrella track (M66–M68) landed the dominant bet end-to-end on `~/unilink` (oracle 89 518 sites across 5 apps → 1031-mutant per-app plan → schema build instrumenting `apps/<app>/lib` → cross-app fallback: a hub mutant fans out to 93 dependents across all 5 apps, recompiled in one `ParallelCompiler.compile` pass with per-app beam routing, source reset clean). The M66 spike's "root untouched" assumption was wrong — six umbrella-only correctness bugs surfaced and were fixed (root must be wrapped for `compile.mut_oracle` discoverability; distinct per-app wrapper module names; idempotent `:mut_oracle`; `MUTALISK_PROJECT_ROOT`-relative sites; single-pass cross-app recompile with `:each_module` routing; per-app `suite_finished` aggregation). M69 operator-expansion mutators shipped opt-in; M71's data (jason ConcatOperator ≈67% noise, plug_crypto BitwiseOperator pseudo-equivalents) → **keep_opt_in**. Worker+report validated on a self-contained 2-app umbrella (8/9 killed, 0 invalid/error). Single-app path byte-identical throughout (golden gates green). M70 (pattern-shape) deferred to v1.21 — the noisiest surface, and umbrella ran long; M71 did not depend on it.

**Explicitly NOT in v1.20:**
- zorbito as a gating acceptance target (v1.21).
- Incremental cross-run history (still held).
- New default-on flips pre-committed (M71 decides from data).
- Tuple/list pattern-arity mutations; function-call deletion / return-value replacement.
- Schema routing for non-literal mutators beyond M69's operators; wrapper guard schemata.
- EnvWalker consolidation implementation (maintenance-trigger gated).

**v1.20 outcome (2026-05-25):** five of six milestones shipped; M70 (pattern-shape) cut via its release valve. M66's spike returned GO but its "root untouched" model proved wrong — M67/M68 surfaced and fixed **six umbrella-only correctness bugs** (root must be wrapped for compiler-task discovery; distinct per-app wrapper module names; idempotent `:mut_oracle`; root-relative site keys; single-pass cross-app `ParallelCompiler.compile` with per-app beam routing; multi-suite result aggregation). Umbrella support is automatic on `apps_path` projects, validated end-to-end on `~/unilink` (5 apps): 89,518 oracle sites → 1031-mutant plan → schema build → a hub mutant fanning out to 93 cross-app dependents recompiled in one pass with beams routed to each app's ebin. Worker+report was validated on a synthetic 2-app umbrella. M69 operators (Concat/Bitwise/Membership) shipped opt-in; M71 kept them opt-in (ConcatOperator ~67% non-productive — needs hazard rules). Single-app path byte-identical throughout.

### v1.21 (4 milestones — close the v1.20 deferrals)

v1.20 landed the umbrella engine but deferred its noisiest catalogue work and its harder validation target. v1.21 closes those threads: mature the operator mutators to graduation-readiness, ship the cut pattern-shape mutators, and push umbrella validation to a real full run (unilink) and the 14-app target (zorbito). No new big subsystem; incremental cross-run history stays held one more cycle.

**Validation correction:** unilink is *not* infra-gated — it runs with local Postgres and its tests pass. So v1.21 gets the real full `mix mut` worker/report run on a 5-app umbrella, closing the v1.20 caveat (that phase was only proven on a synthetic 2-app umbrella). zorbito (14 apps; multi-DB + clustering) is a full-run target where its services can be stood up, with engine-path proof + documented blockers as the floor — not gating.

**Defaults:** the two surfaces (operators, pattern-shape) ship/stay opt-in; M75 decides graduation from the full OSS matrix + equivalent-rate, under the M62 sharpened gate. No default-on flip pre-committed. Elixir floor stays `>= 1.19.0`.

Four milestones. M72 (operator hazard rules) and M73 (pattern-shape) are independent implementation tracks; M74 (umbrella validation) is independent; M75 is the data-gated graduation decision covering both new surfaces. The established impl → validate → decide shape.

**M72 — Operator hazard rules + graduation-readiness.** Give the M69 operators the hazard rules the literal mutators have, targeting ConcatOperator's ~67% non-productive rate first: refuse/skip `++`→`--` in positions that crash or don't type-check (the jason encoder cases), and filter BitwiseOperator's input-dependent pseudo-equivalents where detectable. Membership is already clean. Acceptance: ConcatOperator non-productive rate materially down on jason/real list-binary code; per-mutator invalid + error rates measured; zero stable-id churn for existing mutants; operators remain opt-in pending M75.

**M73 — Pattern-shape mutators (carried M70).** The deferred v2 surface: `_` ↔ named var, pin/unpin (`^x`), built on binding-scope-aware pattern walking (extends the M54 binding tracker into `:match` context). Tuple/list arity stays skipped (M39: non-viable). Strict invalid/equivalent gating — this is the highest-noise surface in the catalogue. Opt-in, fallback-routed. Acceptance: per-mutator unit tests; invalid rate measured + gated; zero stable-id churn for existing mutants.

**M74 — Umbrella validation: unilink full run + zorbito.** Run a real full `mix mut` on unilink (5 apps, local Postgres) — oracle → schema → workers → fallback → per-app + aggregate report — closing the v1.20 synthetic-umbrella caveat. Then zorbito (14 apps): attempt the full run where its services (Postgres/MySQL/SQLite/RabbitMQ/clustering) can be stood up; where a service cannot, prove the engine path (oracle/schema/cross-app fallback across 14 apps — the scale proof) and document the blocker. zorbito is not a gating acceptance target. Acceptance: unilink full run completes with a valid multi-app report; zorbito engine path proven across 14 apps (full run where infra permits); blockers documented; no umbrella regression on the single-app path.

**M75 — Graduation matrix + decisions + BENCHMARKS.** Run the M72 operators and M73 pattern-shape mutators across the full OSS matrix with per-mutator equivalent-rate; apply the M62 sharpened gate (kill ≥60%, equivalent <20% with the ≤2pp single-target tolerance, invalid <10%). Decisions in `docs/decisions/M75_*.md`: per-surface keep_opt_in / graduate. BENCHMARKS v1.21 section (operator + pattern-shape rates; umbrella run results). Acceptance: decisions committed; any graduation is additive-only (existing stable IDs unchanged); `bin/verify` green.

**v1.21 outcome (2026-05-26):** all four milestones shipped; all opt-in surfaces stay `keep_opt_in` (data-gated). M72 hardened the operators (ConcatOperator drops the crash-prone `--`→`++`: jason non-productive 67%→0%; BitwiseOperator drops the `bor`↔`bxor` pseudo-equivalent pair) and added per-mutator invalid/err/nonprod instrumentation. M73 shipped the deferred pattern-SHAPE surface as `Mut.Mutator.Pin` (`^x`→`x` unpin), with the `_`↔var directions documented non-viable by construction (compile-error-if-used / equivalent-if-unused), joining tuple/list arity in the skipped set. M74 closed the v1.20 synthetic-umbrella caveat — a real full `mix mut` on unilink (5 apps, live Postgres+RabbitMQ) produced a valid multi-app report with **0 errors** and live cross-app fallback — and scale-proved the engine on zorbito (14 apps; oracle 150,083 sites, schema build 0 invalid; full worker run infra-blocked, documented). M75's coverage matrix found every surface now runs at **0% invalid** (the hardening worked) but none clears the M62 gate on every target: ConcatOperator fails jason (codegen-context survivors, 67% equivalent), Bitwise/Membership are thin + pseudo-equivalent, and **Pin is flawless on plug (14/14 killed, 0% equivalent/invalid) yet has pins on only one matrix target** — the leading graduation candidate, deferred for multi-target data. M75 also fixed a real Pin hazard (map-key pins `%{^k => v}` are unpinnable → compile error; ~30%→0% invalid). Single-app byte-identity held throughout.

**Explicitly NOT in v1.21:**
- Incremental cross-run history (held one more cycle).
- New mutator families beyond pattern-shape (operators + pattern-shape are the v1.21 surface).
- Tuple/list pattern-arity mutations; function-call deletion / return-value replacement.
- zorbito as a gating acceptance target (full run is best-effort; engine-path is the floor).
- EnvWalker consolidation implementation; wrapper guard schemata.

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
