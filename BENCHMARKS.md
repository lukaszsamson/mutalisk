# Mutalisk Benchmarks

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

### Acceptance evaluation (revised)

- ✓ Decimal reaches mutation execution and produces fanout data (it did not before).
- ☐ Decimal completes within 30-minute budget — static at 33.5 min and coverage at 37.6 min both miss the budget by ~10–25%. The bottleneck is per-test wall-clock × 456 mutants in sequential execution, not test fanout.
- ☐ Coverage reduces fanout ≥10×. Observed fanout reduction: 2.0 → 1.3 tests/mutant ≈ 1.5× on Decimal. The suite is small (only 6 test files in the bench branch with property tests disabled), so static selection already touches few files; coverage gains are correspondingly capped.
- ✓ Next bottleneck documented (sequential per-mutant wall × 456 mutants).
- ✓ plug_crypto outcomes unchanged in static mode.
- ✓ plug_crypto outcomes match within ±0 mutants in coverage mode.
- ✓ BEAM memory bounded under load; peak 82 MB on Decimal vs. 120 GB pre-fix.

v1.5 acceptance: **partially met**. The blocking failure (host OOM and inability to reach mutation execution on Decimal) is resolved. Time and fanout targets are not yet met, but the runtime now produces signal that scopes v1.6 work concretely:

1. **Parallel workers** is the obvious lever — schema_workers wall ≈ 33 minutes is the entire budget. Even 4-way parallelism brings Decimal under 10 minutes.
2. **Decimal's fallback bucket compiles to 75/75 invalid** under both selection modes. This is independent of OOM but surfaced now that Decimal executes. Fallback engine on Decimal hits `CompileError` for every guard mutation; needs a separate diagnostic pass before fallback adds signal on this target.
3. **Decimal-class targets exercise an app-name surface mutalisk had not handled.** Any future target that shares an app name with one of mutalisk's transitive deps' `optional_applications` would have hit the same hang. The fix (jason `runtime: false`) is general — but the wider class is worth keeping in mind: never let mutalisk transitively contribute to the target's runtime app graph.


