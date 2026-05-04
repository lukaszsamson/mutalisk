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
- Wall-clock: failed during oracle/bootstrap compile, before the 30-minute mutation budget could be measured.
- Phase breakdown: unavailable; no Stryker report was produced.
- Coverage match distribution: unavailable.
- Per-mutant fanout reduction estimate: unavailable.
- Identified next bottleneck: Decimal v2.1.1 names its application `:decimal` and also has a dependency entry named `:decimal` after bench injection. The overlay compile failed before plan generation with `Application.fetch_env!(:mutalisk, :user_mix_module)` missing from `Mutalisk.WrappedMixProject.application/0`. This is a target bootstrap/self-dependency conflict, not a selector bottleneck. M16 did not add a Decimal-specific overlay workaround.

### Acceptance evaluation
- ☐ Decimal completes within 30-minute budget
- ☐ Coverage selection reduces per-mutant fanout by >=10x
- ✓ Next bottleneck documented
- ✓ plug_crypto outcomes unchanged in static mode
- ✓ plug_crypto outcomes match within ±1 mutant in coverage mode

v1.5 acceptance is soft-failed for Decimal because the Decimal run did not reach mutation execution and did not produce fanout data. The next decision is a v1.6 bootstrap hardening item for self-dependency/name-conflict targets before parallel-worker evaluation.
