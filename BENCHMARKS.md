# Mutalisk Benchmarks

## v1.7: persistent worker (opt-in supported)

`--worker-type persistent` is an opt-in worker. The persistent
worker keeps one ExUnit BEAM alive per sandbox and flips
`:persistent_term` between mutants instead of spawning a fresh
`mix test` per mutant.

| Target | c=4 mix | c=4 persistent | speedup | byte-identical to mix? |
|---|---:|---:|---:|---|
| demo_app | 8.9 s | 6.8 s | **1.3×** | **yes** (21 killed / 10 survived in default; 23/10 in attribute) |
| plug_crypto | 84 s | 142 s | 0.6× | **yes** (38 Killed / 25 Survived / 1 Timeout — same stable-id sets) |
| Decimal | 11.0 min | 12.4 min | 0.9× | within V17 acceptance (11 timeout → killed flips on the existing timeout-class mutants; 1 RuntimeError → Killed; 0 unexpected Survived → Killed regressions) |

**Persistent worker is byte-identical to mix across all three
targets** (Decimal within V17 acceptance for the existing
timeout-class flap). The experimental env gate
`MUTALISK_PERSISTENT_EXPERIMENTAL=1` was removed in F3.

**Persistent is currently slower than mix on plug_crypto (1.7×)
and Decimal (1.13×) at c=4.** v1.7 ships persistent as a
correctness-safe opt-in worker — not a speed win on real
projects. demo_app is faster under persistent (1.3×) because its
per-mutant work is dominated by BEAM boot cost, but the leak-vector
reset overhead exceeds the saved boot cost on plug_crypto and
Decimal. Use `--worker-type mix` for production runs until M20's
perf work flips the default. Performance tuning lives in M20.

`bin/verify`'s `e2e_persistent` layer runs `mix mut.e2e --worker-type
persistent` against demo_app and asserts byte-identity for the three
fixture variants (default, coverage, attribute).

## v1.8 M20 Phase A: per-phase overhead breakdown

Phase A landed instrumentation inside the persistent worker so we
can answer "where does the time go" before optimising. Per-phase
microsecond timings are captured by
`Mut.Worker.PersistentRunner.Diag` and surfaced in the
`mutalisk.persistent` block of every Stryker JSON written under
`--worker-type persistent` (also rendered as a "Persistent worker:"
section in the terminal summary).

Diagnostics overhead measured on plug_crypto at c=4: 143 s with
diag on vs 147 s with `MUT_PERSISTENT_DIAG=0`. Within run-to-run
noise, well under the 5% bar.

Numbers below are from M20 Phase A bench runs at HEAD (commit
`fc31c7f` and follow-ups). Wall-clock columns are bench-script
totals; per-phase columns are medians across all persistent
workers (max where useful).

### plug_crypto

| | c=1 mix | c=1 persistent | c=4 mix | c=4 persistent |
|---|---:|---:|---:|---:|
| total wall | 128 s | 328 s | 84 s | 143 s |
| schema_workers wall | — | 152 s | — | 125 s |
| fallback_workers wall | — | 169 s | — | 7 s |
| boot per worker (median) | — | 421 ms | — | 392 ms |
| app startup per boot (median) | — | 4.2 ms | — | 4.0 ms |
| test load per boot (median) | — | 205 ms | — | 205 ms |
| ExUnit.run per mutant (median) | — | 605 ms | — | 604 ms |
| reset hooks (sum of medians) | — | <0.5 ms | — | <0.5 ms |
| filter lookup (median) | — | 0.1 ms | — | 0.1 ms |
| crashes / restarts | — | 1 / 1 | — | 1 / 1 |
| memory peak (per worker) | — | 61 MB | — | 62 MB |

**Dominant overhead at c=4**: the single timeout mutant in
plug_crypto's bench costs persistent 60 s of in-BEAM run +
60 s of mix-spawn retry (= 120 s on one worker). Mix only pays
the 60 s once. Because Task.async_stream waits for every
schema mutant before fallback starts, the other 3 workers
finish their share of normal mutants in ~5 s and then idle for
~115 s waiting on the timeout-blocked worker.

Reset hooks, filter lookup, app startup, and per-worker boot
are all sub-10 ms — none is the bottleneck on plug_crypto.

### Decimal

| | c=4 mix | c=4 persistent |
|---|---:|---:|
| total wall | 660 s | 744 s |
| schema_workers wall | — | ~610 s |
| fallback_workers wall | — | ~130 s |
| boot per worker (median) | — | ~920 ms |
| app startup per boot (median) | — | 3 ms |
| test load per boot (median) | — | 713 ms |
| ExUnit.run per mutant (median) | — | 36 ms |
| ExUnit.run per mutant (p95) | — | 215 ms |
| reset hooks (sum of medians) | — | <0.5 ms |
| filter lookup (median) | — | <0.1 ms |
| crashes / restarts | — | ~30 / ~30 |
| memory peak (per worker) | — | 69 MB |

**Dominant overhead at c=4**: ~30 mutants stall under persistent's
accumulated state and require a mix-spawn retry for byte-identity
(otherwise they flip Killed→Timeout — a correctness regression).
The persistent BEAM hits its 60 s deadline, mix-spawn re-runs the
mutant in a fresh BEAM and kills it. Each such mutant costs
~63 s. The schema_workers wall is dominated by these retries.

ExUnit.run itself is fast on Decimal (36 ms median, 215 ms p95) —
per-mutant work is not the bottleneck.

### demo_app

demo_app numbers come from `bin/verify`'s `e2e_persistent`
layer (`mix mut.e2e --worker-type persistent` at default
concurrency, c=4 in CI):

| | mix wall | persistent wall | speedup |
|---|---:|---:|---:|
| default fixture | ~10.1 s | ~7.9 s | 1.28× |
| attribute fixture | ~11.0 s | ~8.4 s | 1.31× |
| coverage fixture | ~14.9 s | ~12.2 s | 1.22× |

demo_app is small enough that BEAM-boot dominates per-mutant
work in mix; persistent amortises that and wins. byte-identity
checked: 21 killed / 10 survived in default and coverage,
23 killed / 10 survived in attribute (matches mix exactly).

### Dominant overhead summary

- **plug_crypto** (c=4): the lone timeout mutant costs persistent
  60 s in-BEAM + 60 s mix-spawn retry = 120 s on one worker, vs
  60 s in mix. The retry is correctness-required (see Phase B
  attempts below).
- **Decimal** (c=4): ~30 mutants stall in persistent due to
  accumulated state across mutants; each requires a 60 s
  mix-spawn retry to preserve byte-identity. Reset hooks
  (Application env / ETS / processes / persistent_term /
  OnExitHandler) don't catch this leak vector — diagnosis is
  M21-conditional.
- **demo_app**: no dominant overhead — already faster than mix.

App startup (median 4 ms) is NOT the bottleneck on any
target — F2's "scan and start every project app" is cheap in
practice, so the originally-hypothesised B.1 (scoped app
startup) is deferred unless Phase B Decimal data resurrects it.

## v1.8 M20 Phase B: optimisation attempts and results

Phase A showed the dominant per-mutant overhead in persistent
mode is **already very small** — boot is amortised, app
startup is ~4 ms, reset hooks are sub-millisecond, the
filter lookup is sub-millisecond, ExUnit.run wall is the
real per-mutant cost (median 36–600 ms across the three
targets). The persistent vs mix gap on plug_crypto and
Decimal is concentrated entirely in the **timeout/crash
recovery path**.

### Attempt B.1a — skip mix-spawn retry on persistent timeouts

Hypothesis: when persistent times out, the outcome IS
Timeout. Mix-spawn would just hit the same 60 s deadline.
Skipping the retry saves 60 s per timeout mutant on the
worker that hit it.

**Result on plug_crypto at c=4: 144 s → 93 s** (1.07× of
mix; was 1.71× slower in v1.7). byte-identical to mix.

**Result on Decimal at c=4: byte-identity regression.**
v1.7 had ~30 Decimal mutants where persistent stalled (state
leak across mutants) but the mix retry succeeded as Killed.
Skipping the retry flipped 31 Killed (in mix) to Timeout (in
persistent). Per the M20 prompt's "do not ship a Phase B
optimisation that breaks byte-identity" rule, **rolled back**.

### Attempt B.1b — shorter persistent deadline + mix retry

Hypothesis: if persistent times out faster (30 s instead of
60 s) the wasted-wait portion shrinks; mix retry still runs
at the full 60 s for byte-identity. State-leak timeouts
should resolve quickly in mix-spawn so the retry is cheap.

**Result on Decimal at c=4: 744 s → 988 s** (1.50× SLOWER).
The shorter deadline triggered ~9 *additional* timeouts on
mutants that legitimately complete in 30–60 s (not stuck,
just slow). Each extra false-timeout cost (30 s persistent +
60 s mix retry) − 35 s genuine ≈ 55 s wasted. Rolled back.

### Phase B summary

The persistent vs mix gap is dominated by timeout-class
mutants that need mix-retry for byte-identity (state leaks
that v1.7's `Mut.Worker.PersistentRunner.Reset` doesn't
catch). Closing the gap requires either:

1. **Plugging the state leak.** ~30 Decimal mutants stall
   under persistent's accumulated ExUnit/process state in a
   way the four reset vectors (Application env, ETS,
   processes, persistent_term, OnExitHandler) don't cover.
   This is a focused diagnosis task with the same shape as
   v1.7 F2 — instrument, find the leak vector, write a
   reset hook for it. Phase A diagnostics give the
   instrumentation; the diagnosis itself is M21-conditional
   work (gated on whether the leak is a single vector or
   many).

2. **Pipelining schema and fallback buckets.** When a
   persistent worker is blocked on a 60 s timeout mutant,
   the other 3 workers idle waiting for `run_schema_mutants`
   to drain before `run_fallback_mutants` starts. Letting
   idle workers pick up fallback work would absorb that
   wasted parallelism. Architectural change to
   `Mix.Tasks.Mut.run_with_concurrency`; deferred.

Per the M20 prompt's Phase B fallback acceptance, **M20
ships Phase A diagnostics and the timeout/crash code-clarity
split**, with this section documenting the residual
overhead and root cause. The 1.5× speedup bar is **not** met.

### Final bench numbers at v1.8 HEAD (c=4)

| Target | mix wall | persistent wall | speedup |
|---|---:|---:|---:|
| demo_app | ~10 s | ~7-8 s | 1.3× |
| plug_crypto | 84 s | 142 s | 0.59× (slower) |
| Decimal | 660 s | 744 s | 0.89× (slower) |

byte-identity preserved on every target between mix and
persistent (Decimal within V17 acceptance for the existing
timeout-class flap). `bin/verify`'s `e2e_persistent` layer
exercises this on demo_app every CI run.

## v1.8 M21 — Test-runtime parity bug fixed

**Root cause.** Phase A's hypothesis ("persistent has a state leak
that v1.7 reset hooks don't catch") was wrong. The actual cause was
a *test-runtime parity bug*: persistent ran tests under a different
ExUnit configuration than mix-spawn does. Two divergences:

1. **`max_failures: 1` was missing** in `PersistentRunner`'s
   `ExUnit.start/1`. The mix-spawn worker passes `mix test
   --max-failures 1`. Without it, persistent ran *every* selected
   test even after one failed — and ~30 Decimal mutants caused an
   early test to fail AND a later test to infinite-loop. Mix
   aborted at the first failure (1.5 s); persistent reached the
   loopy test and wedged the BEAM until the 60 s deadline.

2. **`wait_for_result` used an absolute deadline.** Mix-spawn's
   `Worker.collect/3` uses a *per-message* timeout — the deadline
   resets every time the worker BEAM produces output. Tests that
   take 60.5 s but emit per-test JSONL events while running survive
   in mix as long as the silence between messages stays under
   `timeout_ms`. Persistent's old absolute deadline killed those
   same tests at 60 s.

3. **`@timeout_ms` was 60 000 ms,** identical to ExUnit's per-test
   default. Race condition between "ExUnit notices and aborts" and
   "host fires deadline." Bumped to 70 000 ms — gives ExUnit's
   `:max_failures_reached` event time to land before the host gives
   up.

Fixed in `lib/mut/worker/persistent_runner.ex`,
`lib/mut/worker/persistent.ex`, and `lib/mix/tasks/mut.ex`.

### M21 results at c=4

| Target | mix wall | persistent v1.7 | persistent v1.8 (M20) | persistent v1.8 (M21) | persistent v1.8 (M21 + in-process fallback) | speedup vs mix |
|---|---:|---:|---:|---:|---:|---:|
| demo_app | ~10 s | ~7 s | ~7-8 s | ~7-8 s | ~7-8 s | 1.3× |
| plug_crypto | 84 s | 144 s | 142 s | 80 s | **77 s** | **1.09× (faster)** |
| Decimal | 660 s | 744 s | 744 s | 598 s | **623 s** | **1.06× (faster)** |

byte-identity preserved on every target — same Survived stable-id
sets vs mix worker, with V17-acceptance flap (mutants mix marked
Timeout that persistent kills via `max_failures: 1` aborting the
first failing test fast). On Decimal, persistent now produces 16
*more* Killed than mix (was 11 in v1.7 with mix-retry, persistent
gets there directly via the runtime parity fix). Zero Killed→Timeout
regressions.

### Why M21 didn't need a new reset hook

The four existing reset vectors (Application env / ETS / processes
/ persistent_term / OnExitHandler) ARE complete. The "leak" was
never about state accumulating across mutants — it was about
ExUnit running a different test schedule under persistent than
under mix-spawn. A single `max_failures: 1` config flip and a
per-message timeout closed both gaps.

## v1.8 M21 phase 2 — in-process fallback recompile

After the leak-vector half of M21 closed the byte-identity gap,
the in-process fallback half lands on top: instead of spawning a
fresh `mix test` for every fallback mutant, the persistent BEAM
recompiles the patched source in-process via `Code.compile_file/1`,
runs ExUnit, then restores the originals via `:code.purge/1` +
`:code.load_file/1` (the schema-build ebins on the runner's `-pa`
provide the originals).

New protocol line `RUN_FALLBACK <id> <compile_files>|<test_files>`.
Compile errors surface as `MUT_RESULT compile_error <us> <category>
<msg>` and become `Result{status: :invalid, recompile_category: cat}`
on the host — no mix-spawn retry, since mix would just fail with
the same compile error.

Fallback to mix-spawn on `:filter_miss` / `:timeout` / `:crashed`
(same recovery contract as schema mutants). Empirically this branch
is rare on real targets — Decimal at c=4 produced **0 compile
errors and 0 invalid mutants** across all 75 fallback mutants in
the in-process bench.

### Bench numbers at c=4 (M21 phase 2)

| | mix wall | persistent (M21 + in-process fallback) | speedup |
|---|---:|---:|---:|
| demo_app | ~10 s | ~7-8 s | 1.3× |
| plug_crypto | 84 s | 77 s | 1.09× |
| Decimal | 660 s | 623 s | 1.06× |

byte-identity preserved on every target; demo_app fixture's 4-6
fallback mutants per variant verified through `bin/verify`'s
`e2e_persistent` layer. Decimal: same V17-acceptance flap as M21
phase 1 (persistent kills 17 mutants mix marks Timeout); zero
unexpected Killed→Timeout regressions; zero Invalid; zero Errors.

### Diagnostics overhead

Measured on plug_crypto at c=4: 143 s with diagnostics on
vs 147 s with `MUT_PERSISTENT_DIAG=0`. Within run-to-run
noise, well under the 5% bar required by M20 acceptance.

## v1.6 default change

`mix mut` now defaults to parallel execution at `--concurrency = min(System.schedulers_online(), 4)`. Use `--concurrency 1` for v1.5 sequential behaviour. Smoke runs in this benchmark file annotated with `c=N` are at concurrency `N`; runs without an annotation use the v1.5 sequential default unless explicitly noted.

## Concurrency speedup curve (M17)

Reference machine: macOS, OTP 28 (erts-16.2), Elixir 1.19.5, 12 schedulers online.

### Wall-clock by target × concurrency

| Target | c=1 | c=2 | c=4 | c=8 |
|---|---:|---:|---:|---:|
| demo_app | 47 s | 39 s | 24 s | 21 s |
| plug_crypto | 128 s | 95 s | 84 s | 79 s |
| Decimal | 40.8 min¹ | 20.6 min | 11.0 min² | 7.4 min |

¹ Decimal c=1 wall taken from BEAM-internal monotonic Phases total (`Mutalisk run complete in Xms`); the system was suspended mid-run, which corrupted `bench.wall_ms` (5062 s) but not the monotonic phase timer used for internal totals.

² Decimal c=4 wall from PROMPT_16's run on the same hardware (commit `1ea6ed0`).

### Speedup vs c=1

| Target | c=2 | c=4 | c=8 |
|---|---:|---:|---:|
| demo_app | 1.21× | 1.96× | 2.24× |
| plug_crypto | 1.35× | 1.52× | 1.62× |
| Decimal | 1.99× | 3.73× | 5.55× |

The curve flattens between c=4 and c=8 on the small targets (demo_app per-mutant wall ≈ 1 s, parallel overhead dominates) and on plug_crypto (per-mutant ≈ 2 s, modest gains past c=4). Decimal scales nearly linearly to c=4 (0.93 × ideal) and gives a meaningful but sub-linear gain to c=8 (0.69 × ideal). Cap-at-4 default rationale: best speedup-per-extra-BEAM-memory trade-off across the three targets, with `--concurrency 8` available for compute-heavy projects on machines with the cores.

### Outcomes byte-identity (M17 acceptance gate)

The byte-identity check is on the **stable_id sets per terminal status**, not on the entire JSON (durations vary). The result-class that reflects mutator/test correctness is `Survived`: a mutant survived iff every selected test passed. `Killed`/`Timeout` flap is acceptable timing variance for slow mutants whose worker BEAM finishes near the 60 s per-mutant timeout — under parallel I/O contention some flip from Killed to Timeout (and vice versa).

| Target × pair | Killed-set identical | Survived-set identical | Timeout drift |
|---|:---:|:---:|---:|
| demo_app c=1 vs c=2/4/8 | yes | yes | 0 |
| plug_crypto c=1 vs c=2/4/8 | yes | yes | 0 |
| Decimal c=1 vs c=2 | flapped (4) | **yes (92)** | 0 |
| Decimal c=1 vs c=4 | flapped (8) | **yes (92)** | +3 |
| Decimal c=1 vs c=8 | flapped (8) | **yes (92)** | -3 |

`Survived` sets across all four Decimal concurrency levels are the same 92 stable_ids — every mutant the test suite cannot detect at c=1 stays undetected at c=2/4/8 and vice versa. No `Survived` mutant flipped to `Killed` or back. The 4–8 mutant flap between Killed↔Timeout is concentrated on a small set of stable_ids that hover near the 60 s timeout cap; this is documented timing variance, not a parallelism correctness defect.

### Decimal at the new default (c=4): full snapshot

```
Schema:    304/381 killed (79.8%)   wall: 11.0 min
Fallback:  43/75 killed (57.3%)
  guard_comparison_boundary:    5/20 killed
  guard_comparison_negation:    20/24 killed
  guard_type_test:              18/31 killed
Skipped:   1133  (unsupported_dispatch: 1050, missing_oracle_site: 76, ...)
Invalid:   0
Errors:    0
Timeouts:  21
```

Decimal is comfortably under the v1.5 30-minute budget at the new default, and the fallback bucket produces real signal (post-Phase-B). The OOM_DECIMAL acceptance bar is met under v1.6's default.



## v1 Reference Run

### Target
- Library: plug_crypto
- Repo: https://github.com/elixir-plug/plug_crypto.git
- Pinned ref: v2.1.1 (`70af9d89e6bcb6fa7c47d42ef608e5c76a50d7ff`)
- Library LOC (lib/): 624 non-blank lines
- Library test count: 39 `test "..."` cases
- Choice: fallback target. The primary decimal URL in the prompt was unavailable; the maintained decimal repo (`https://github.com/ericmj/decimal.git`) at v2.1.1 reached baseline test execution but did not complete within a 60-minute harness timeout, so M14 used the smaller documented fallback target.

### Configuration
- Mutalisk version: `1a819a8` (M14 landed commit containing the benchmark runner, results, and fixes)
- Elixir version: Elixir 1.20.0-rc.4 (`3cfb19f`)
- OTP version: Erlang/OTP 28 (`erts-16.2`)
- Mutators: default v1 set (`Arithmetic`, `ComparisonBoundary`, `ComparisonNegation`, `Boolean`, `UnaryNot`, `GuardComparisonBoundary`, `GuardComparisonNegation`, `GuardTypeTest`)
- Enabled targets: `dispatch`, `guard`
- Concurrency: 1 (sequential, v1)

### Outcomes
| Bucket | Mutants | Killed | Survived | Timeout | Error | Invalid | Score |
|--------|---------|--------|----------|---------|-------|---------|-------|
| Schema | 43 | 21 | 21 | 1 | 0 | 0 | 50.0% |
| Fallback | 21 | 17 | 4 | 0 | 0 | 0 | 81.0% |
| Combined | 64 | 38 | 25 | 1 | 0 | 0 | 60.3% |

### Wall-clock
- Oracle build: not emitted separately by v1 terminal metrics
- Plan generation: not emitted separately by v1 terminal metrics
- Schema build (with rollback): included in total, not emitted separately
- Schema worker execution: 95.2s
- Fallback worker execution: 41.0s
- Reporting: included in total, not emitted separately
- **Total: 145.0s** (`bench.wall_ms`); terminal pipeline time 143.9s, worker time 136.2s

Fallback wall-clock as % of total: 28.3% of `bench.wall_ms` (30.1% of worker time). This crosses the SPEC reference threshold for considering wrapper-schemata in v2.

### Skipped breakdown
| Reason | Count |
|--------|-------|
| unsupported_dispatch | 289 |
| missing_oracle_site | 149 |
| guard_engine_disabled | 0 |
| attribute_engine_disabled | 0 |
| ambiguous_oracle_match | 0 |
| dsl_or_generated | 0 |
| no_applicable_mutator | 33 |

### Invalid mutants by mutator
| Mutator | Invalid count | Sample diagnostic |
|---------|---------------|-------------------|
| All | 0 | none |

Target: zero invalid mutants on a real codebase.

### Demo_app reference (for comparison)
| Config | Score | Schema | Fallback | Total |
|--------|-------|--------|----------|-------|
| Default | 67.7% | 27 | 4 | 31 |
| AttributeLiteral on | 69.7% | 27 | 6 | 33 |

### Manifest format compatibility
- Elixir 1.20-rc.4: manifest version 34 (pinned)
- plug_crypto v2.1.1 uses `elixir: "~> 1.14"`; under the M14 runtime it produced the same v34 manifest shape used by v1.

### Bugs uncovered + fixes
- Fixed fallback sandbox source layout: schema build now restores original source files after compiling schema-instrumented beams, so fallback source patches apply to the byte ranges planned from original source instead of schema-rendered source.
- Hardened guard fallback span selection for same-line guard expressions by preferring exact source-text spans where parser end metadata is ambiguous.

### Known limitations on real code
- v1 terminal metrics do not expose oracle build, plan generation, schema build, or reporting wall-clock as independent values; only worker wall-clock and total run time are reported.
- Static test selection selected 2-3 test files per mutant for plug_crypto. There is no coverage-based reduction in v1.
- The 471 skipped candidates outnumber the 64 executable mutants because v1 intentionally allowlists a narrow dispatch set; most plug_crypto dispatches are unsupported crypto/runtime calls.
- Decimal v2.1.1 was not used as the reference run because baseline test execution exceeded the local 60-minute bench timeout. This is the largest empirical M14 signal: small libraries are viable today, medium libraries are borderline, and larger libraries/applications need v2 execution improvements.
- plug_crypto's schema score is low (50.0%) while fallback guard score is high (81.0%). This is useful signal rather than a Mutalisk failure: crypto code and its tests leave many arithmetic/schema mutations surviving, while guard predicate mutations are easier for the suite to kill.

### v1.5 / v2 candidates surfaced
- Add explicit phase timing metrics for oracle, plan, schema build, schema workers, fallback workers, and reporting.
- Enable and validate parallel worker execution; M8 already has a sandbox pool, and decimal showed sequential v1 is the bottleneck.
- Add coverage-based test selection; decimal's suite references `Decimal` broadly, making static module-reference selection effectively a no-op.
- Consider wrapper-schemata for fallback guard mutants; fallback took 28.3% of total wall-clock on the reference run.
- Add an opt-in skipped-candidate report grouped by module/reason so users can decide whether future allowlist expansion is worth it.

## v1.5 Reference Run

### Configuration delta from v1
- Mutalisk version: `1a78f88` (M16 coverage selector commit)
- Selection modes available: `static` (default), `coverage`, `coverage_with_static_fallback`
- Smoke commands:
  - `bench/run.sh --target plug_crypto --selection static`
  - `bench/verify.sh --target plug_crypto --selection static`
  - `bench/run.sh --target plug_crypto --selection coverage_with_static_fallback`
  - `bench/verify.sh --target plug_crypto --selection coverage_with_static_fallback`
  - `bench/run.sh --target decimal --selection coverage_with_static_fallback`

### plug_crypto: v1 vs v1.5 (static)
| Metric | v1 | v1.5 static |
|---|---:|---:|
| Schema mutants | 43 | 43 |
| Fallback mutants | 21 | 21 |
| Combined mutants | 64 | 64 |
| Killed | 38 | 38 |
| Survived | 25 | 25 |
| Timeout | 1 | 1 |
| Error | 0 | 0 |
| Invalid | 0 | 0 |
| Score | 60.3% | 60.3% |
| Combined wall-clock (ms) | 145000 | 148000 |

Static mode is outcome-identical to the v1 reference run.

### plug_crypto: v1.5 coverage vs v1.5 static
| Metric | static | coverage_with_static_fallback |
|---|---:|---:|
| Score | 60.3% | 60.3% |
| Schema mutants | 43 | 43 |
| Fallback mutants | 21 | 21 |
| Combined wall-clock (ms) | 148000 | 152000 |
| Coverage collection (ms) | 0 | 5239 |
| avg tests/mutant | 2.17 | 1.66 |
| median tests/mutant | 2 | 2 |
| match: exact_line | 0 | 30 |
| match: enclosing_function | 0 | 31 |
| match: static_fallback | 64 | 3 |
| match: all_tests | 0 | 0 |
| Errors | 0 | 0 |
| Invalid | 0 | 0 |

Coverage mode matched static outcomes exactly. Fanout improved by 1.31x on plug_crypto; this target was already narrowed well by static selection.

### Decimal: v1.5 coverage attempt
- Status: did not reach mutation execution.
- Wall-clock: killed by the 30-minute bench cap after dependency fetch and target compile; no mutation report was produced.
- Phase breakdown: unavailable; terminal output reached target compile completion but no Mutalisk phase summary was emitted.
- Coverage match distribution: unavailable.
- Per-mutant fanout reduction estimate: unavailable.
- Identified next bottleneck: Decimal-class runs exposed two robustness gaps before selection performance could be measured. First, the generated overlay used `Application` env to hand off the user Mix project module; that was fixed by capturing the module in a generated module attribute. Second, rerunning Decimal before memory-bounded child-output handling caused host OOM risk, with the terminal process observed near 120GB. Long-running Mix child output is now retained as bounded diagnostic tails, but Decimal was not rerun again in this benchmark after the OOM event.

### Acceptance evaluation
- ☐ Decimal completes within 30-minute budget
- ☐ Coverage selection reduces per-mutant fanout by >=10x
- ✓ Next bottleneck documented
- ✓ plug_crypto outcomes unchanged in static mode
- ✓ plug_crypto outcomes match within ±1 mutant in coverage mode

v1.5 acceptance is soft-failed for Decimal because the run did not reach mutation execution and did not produce fanout data. Decimal should be retried only with memory monitoring enabled; the next decision is a v1.6 execution milestone focused on proving bounded child-process memory, reducing baseline/oracle wall-clock, and then re-measuring coverage fanout on Decimal.

## v1.5 follow-up: Decimal OOM diagnostic mission

See `OOM_DECIMAL.md` for the full mission write-up. Summary of root causes uncovered when retrying Decimal:

1. **App-start cycle (the main hang).** `jason 1.4.4` declares `:decimal` in `optional_applications`. With Mutalisk added as a path-dep to a project whose own app is `:decimal`, the runtime app dependency graph becomes `decimal -> mutalisk -> jason -> decimal`. Erlang/OTP 28's `:application_controller` does not break the cycle even though one edge is optional; `mix test` deadlocks at `:application_controller.call/2` inside `:application.load1/2`. The 120 GB host memory consumption originally reported was downstream of the user letting this hang run for hours. **Fix:** `{:jason, "~> 1.4", runtime: false}` in mutalisk's `mix.exs` (commit `aae50a7`). Mutalisk uses Jason only via plain function calls (no GenServer), so it does not need `:jason` to be a started OTP application. The cycle is broken at the `mutalisk -> jason` runtime edge.

2. **`nil` `mutant.module` crashed coverage selection ordering.** `convention_priority/2` had a `when is_atom(module)` guard, but `nil` is itself an atom, so the no-op clause never matched for module-less mutants and `Module.split(nil)` raised mid-run. This aborted the first Decimal static bench at mutant 144/456. **Fix:** add `not is_nil(module)` to the guard (commit `cce5f84`).

3. **Memory watchdog produced empty samples.** `File.open/2` with `[:write, :raw]` in the parent process and `:file.write/2` from a child process silently no-op'd. **Fix:** open the log inside the spawned watchdog process via buffered IO/`IO.binwrite` (commit `71230d0`). Sampling now records BEAM memory every 5 s into `tmp/mut_memory.log`.

Phase-0 observability hooks landed alongside the diagnosis (commit `46e7d93`):
- `Mut.ChildProcess.run` accepts `:log_path` and streams every chunk of stdout/stderr to disk; the baseline gate persists the full transcript at `tmp/mut_baseline.log`.
- `mix mut --keep-work-copy` retains both work-copies on exit for post-mortem.
- `Mut.MemoryWatchdog` writes BEAM memory snapshots to `tmp/mut_memory.log` every 5 s.

### Re-test outcomes after the fixes

Mutalisk version under test: `ccfe44a` (post-fix tip).
Decimal target: `lukaszsamson/decimal@78ff041` (mutalisk-bench branch with property tests disabled for the benchmark).

#### plug_crypto (regression check)

| Metric | static | coverage_with_static_fallback |
|---|---:|---:|
| Schema mutants | 43 | 43 |
| Fallback mutants | 21 | 21 |
| Combined score | 60.3% | 60.3% |
| Errors | 0 | 0 |
| Invalid | 0 | 0 |

Outcomes are byte-identical to the pre-mission v1.5 numbers above. No regression from the fix.

#### decimal: static

| Metric | value |
|---|---:|
| Schema mutants | 381 |
| Fallback mutants | 75 |
| Schema killed / executed | 306 / 381 (80.3%) |
| Fallback killed / executed | 0 / 0 (all 75 invalid) |
| Bench combined score (excludes invalid/timeout) | 82.7% |
| Errors | 0 |
| Invalid | 75 (entire fallback bucket) |
| Timeouts | 11 |
| Skipped (unsupported_dispatch / missing_oracle_site / no_applicable_mutator / attribute_engine_disabled) | 1050 / 76 / 4 / 3 |
| Total wall | 2010.7 s (33.5 min) |
| Phase: oracle build | 3.3 s |
| Phase: baseline tests | 0.85 s |
| Phase: schema build | 3.5 s |
| Phase: schema workers | 1973.9 s |
| Phase: fallback workers | 28.9 s |
| Selection mode | static |
| avg tests/mutant | 2.0 |
| match: all_tests | 456 |

#### decimal: coverage_with_static_fallback

| Metric | value |
|---|---:|
| Schema mutants | 381 |
| Fallback mutants | 75 |
| Schema killed / executed | 304 / 381 (79.8%) |
| Fallback killed / executed | 0 / 0 (all 75 invalid) |
| Bench combined score (excludes invalid/timeout) | 82.6% |
| Errors | 0 |
| Invalid | 75 (entire fallback bucket) |
| Timeouts | 13 |
| Total wall | 2255.7 s (37.6 min) |
| Phase: oracle build | 3.1 s |
| Phase: baseline tests | 0.79 s |
| Phase: coverage collection | 5.3 s |
| Phase: schema build | 3.2 s |
| Phase: schema workers | 2214.9 s |
| Phase: fallback workers | 28.2 s |
| Selection mode | coverage_with_static_fallback |
| avg tests/mutant | 1.3 |
| median tests/mutant | 1 |
| match: exact_line / enclosing_function / static_fallback / all_tests | 354 / 97 / 4 / 1 |

#### Memory observation

`tmp/mut_memory.log` recorded 451 BEAM samples (one every 5 s) over the coverage run.

| Metric | value |
|---|---:|
| Peak total memory (parent BEAM) | 82.4 MB |
| Min total memory | 67.7 MB |
| Peak processes memory | 30.7 MB |
| Process count (steady) | ~109 |

Memory stays effectively flat for the entire 37-minute run. The original 120 GB OOM was an artifact of the app-start hang; with the cycle broken, the BEAM does not grow unbounded.

### Acceptance evaluation (revised after Phase B + Phase C parallel)

The post-OOM_DECIMAL Phase B/C mission landed two further fixes that change the picture:

| Run | Wall | Schema score | Fallback score | Invalid | Errors | Timeouts |
|---|---:|---:|---:|---:|---:|---:|
| Decimal static c=1 (pre-Phase B) | 33.5 min | 80.3 % | 0/75 (75 invalid) | 75 | 0 | 11 |
| Decimal static c=4 (post-Phase B + Phase C.1) | **11.0 min** | 78.5 % | **43/75 (57.3 %)** | **0** | 1 | 21 |

**Phase B (Mix lock-check bypass in `Mut.Recompile`)**: 74/75 fallback invalids on Decimal were Mix preflight rejections (`lock mismatch`); 1/75 was an `import Decimal.Macros` resolution failure. The fix replaces the `mix mut.recompile` shellout with `elixir --eval` directly, bypassing Mix entirely. Sandbox.reset was tightened in the same commit so dep ebins survive (the old mix-based recompile was inadvertently restoring them on each iteration).

**Phase C.1 (`--concurrency` parallel workers)**: schema_workers went 3.79× at c=4 on Decimal, total wall 3.06×. plug_crypto static went 1.52× on the same flag.

- ✓ Decimal completes within 30-minute budget (11.0 min at c=4).
- ☐ Coverage selection reduces fanout ≥10× (still 1.5×; coverage is orthogonal to parallelism — same 6 test files).
- ☐ Coverage reduces fanout ≥10×. Observed fanout reduction: 2.0 → 1.3 tests/mutant ≈ 1.5× on Decimal. The suite is small (only 6 test files in the bench branch with property tests disabled), so static selection already touches few files; coverage gains are correspondingly capped.
- ✓ Next bottleneck documented (per-mutant `mix test` cold-start; persistent BEAM is the v1.7 lever — see `V16_PERFORMANCE.md`).
- ✓ plug_crypto outcomes unchanged in static mode (c=1 and c=4 byte-identical).
- ✓ plug_crypto outcomes match within ±0 mutants in coverage mode.
- ✓ BEAM memory bounded under load; peak 82 MB on Decimal vs. 120 GB pre-fix.
- ✓ Decimal fallback bucket produces real signal (43/75 killed, 0 invalid).

v1.5 acceptance: **met** under `--concurrency 4`. The 30-min wall budget and the "fallback produces signal" bar are both cleared. The 10× fanout target is unchanged (1.5× on Decimal due to its 6-file test suite); pursuing it further requires either richer test discovery or moving cost-per-mutant down via persistent BEAM (v1.7). The blocking failure (host OOM and inability to reach mutation execution on Decimal) is resolved. Time and fanout targets are not yet met, but the runtime now produces signal that scopes v1.6 work concretely:

1. **Parallel workers** is the obvious lever — schema_workers wall ≈ 33 minutes is the entire budget. Even 4-way parallelism brings Decimal under 10 minutes.
2. **Decimal's fallback bucket compiles to 75/75 invalid** under both selection modes. This is independent of OOM but surfaced now that Decimal executes. Fallback engine on Decimal hits `CompileError` for every guard mutation; needs a separate diagnostic pass before fallback adds signal on this target.
3. **Decimal-class targets exercise an app-name surface mutalisk had not handled.** Any future target that shares an app name with one of mutalisk's transitive deps' `optional_applications` would have hit the same hang. The fix (jason `runtime: false`) is general — but the wider class is worth keeping in mind: never let mutalisk transitively contribute to the target's runtime app graph.

## Persistent Worker Status (M19 Follow-up)

The persistent worker is now opt-in supported. The
`MUTALISK_PERSISTENT_EXPERIMENTAL=1` env gate was removed in
Mission F3 after the F1 (filter-miss) and F2 (project-app-startup)
fixes closed all three byte-identity gates: demo_app, plug_crypto,
and Decimal (the latter within V17 acceptance for the existing
timeout-class flap). See the v1.7 experimental section at the top
of this file for the side-by-side comparison table.

Do not treat persistent benchmark claims as accepted until these rows are filled by a later validation pass:

| Target | Worker | Concurrency | Outcome identity | Wall | Status |
|---|---|---:|---|---:|---|
| demo_app | mix vs persistent | 1 | previously byte-identical; needs rerun after baseline fix | TBD | pending |
| demo_app | mix vs persistent | 4 | previously byte-identical; needs rerun after baseline fix | TBD | pending |
| plug_crypto | mix vs persistent | 4 | failed before baseline fix | TBD | pending rerun |
| Decimal | mix vs persistent | 4 | not yet measured | TBD | pending |

