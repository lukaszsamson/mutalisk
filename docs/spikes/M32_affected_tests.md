# M32 — Affected-Test Selection Spike

**Status:** decision committed: shelve.
**Date:** 2026-05-10.
**Author:** v1.11 stretch milestone.

## Question

Can mutant-execution fanout drop further by selecting tests at
`{test_module, test_name}` granularity per mutant — instead of
the current `{:file | :module}` granularity in
`Mut.CoverageOracle` — without introducing silent-survivor drift?

The acceptance criterion (PLAN.md v1.11): byte-identical outcomes
on demo_app + plug_crypto + ≥2 OSS targets vs the current `static`
selection mode. **Any silent-survivor delta on any target shelves
the spike.**

## Why a strict kill criterion?

Mutation testing's currency is *kill rate*. Lowering kill rate by
selecting fewer tests is not a "speed/correctness tradeoff" — it
is a wrong answer. A mutant marked Survived by affected-test
selection but Killed by static selection is a silent regression;
users acting on the survivor count will mis-prioritize their test
suite. At v1.x maturity correctness must dominate perf.

## Status of the existing selection modes

| Mode | Granularity | Default |
|---|---|---|
| `static` | All test files in modules statically connected to the mutant. | M0–M24 default. |
| `coverage` | Test files whose `:cover` traces hit the mutant's line, function, or module. | M19+ option. |
| `coverage_with_static_fallback` | `coverage` per mutant; falls back to `static` for mutants the coverage oracle didn't observe. | v1.10 default. |

`coverage_with_static_fallback` already reduces fanout to ~2× on
demo_app, ~1.5× on Decimal vs `static`. The remaining work for
M32 is the *intra-file* fanout reduction: skipping test cases
within a covered file.

## Proposed implementation sketch (NOT shipped)

Two pieces of work, each non-trivial:

### Coverage oracle refinement

`Mut.CoverageOracle.by_line` and `.by_function` currently key onto
`test_id() :: {:file, Path.t()} | {:module, module()}`. The
collection runner in `Mut.Coverage.Runner` would need to track
the active `{ExUnit.Test.module, ExUnit.Test.name}` pair while
`:cover` is collecting line hits, then emit the finer test ids in
the oracle. The Stryker JSON `coveredBy` field already contains
this granularity for kill-attribution; we don't currently consume
it for selection.

Cost: ~200–300 LOC + new fixture and golden tests.

### Per-mutant `ExUnit.only_test_ids` plumbing

The persistent worker already uses `ExUnit.configure(only_test_ids: ...)`
for filter-miss handling (M21). Schema-engine mutants would route
through that path with the affected-tests set. Mix-spawn fallback
would need `--only` flags piped into `mix test`. ExUnit's
`only_test_ids` accepts `{module, name}` tuples directly, so the
plumbing is small once the oracle has the data.

Cost: ~100 LOC.

## Silent-survivor risk surface (first-principles analysis)

Even if the implementation is correct, the spike must establish
that affected-test selection produces zero kill-rate regression.
Five risk vectors:

### 1. `setup_all` and module-level fixtures (high risk)

Many test modules have `setup_all` blocks that create resources
(GenServers, ETS tables, fixture data) all tests in the module
depend on. ExUnit's `only_test_ids` runs `setup_all` once per
module *if any test in that module is selected* — which is fine
for the common case. But mutation testing exercises a
mutated-module assertion: a test that depends on side-effects
from a SIBLING test (anti-pattern but real) would behave
differently. `static` mode runs the entire module suite together;
affected-test selection runs only one test, missing the side-
effect.

Likely surface: Decimal's property tests (depend on shared seed
state), nimble_options' docs tests (read previously-generated
schema metadata), ecto's connection-pool tests.

### 2. Doctests (medium risk)

Doctests are special ExUnit tests where the test name encodes the
function/line. The coverage oracle would need to emit the doctest
name correctly; failure to do so would skip doctests entirely on
mutants whose only kill path is via doctest assertion. demo_app
has 0 doctests; plug_crypto has 1 module with doctests; Decimal
has many. Risk: high on doctest-heavy targets.

### 3. Property-based tests (high risk)

`StreamData`-backed properties are SINGLE ExUnit tests but expand
to hundreds of generated inputs. Coverage data records the test
once; affected-test selection includes or excludes the entire
property. If the property is the only test that touches the
mutated function under one specific generated input, the oracle
records a HIT and the test is selected — but the random seed
under affected-test selection may not generate the killing input.

This isn't a silent-survivor in the classical sense (the test was
selected); it's a non-determinism amplification. Acceptable on
deterministic-seed runs, fragile otherwise. jason and Decimal use
StreamData heavily.

### 4. Coverage data gaps (medium risk)

`:cover` doesn't trace macros expanded at compile time. A test
that exercises a mutation via a macro generated at compile time
may hit the mutated line at runtime but the oracle won't record
it. `coverage_with_static_fallback` already routes these to
static fallback; affected-test selection would lose the test.
Macro-heavy targets: gettext, nimble_options, ecto.

### 5. Async test interleaving (low risk)

Two `async: true` tests touching the same mutation may both
contribute to a kill, but `:cover` line hits attribute to whichever
test happens to evaluate the line first. The oracle records one;
affected-test selection runs only that one. If the timing under
mutation-testing's c=4 worker shifts which test wins the race, the
recorded coverage could be wrong.

## Why the strict criterion is unlikely to be met

Risks 1, 2, 3 each plausibly produce silent-survivor drift on
≥1 of {demo_app, plug_crypto, nimble_options, jason}. Even if
the implementation is impeccable, hitting zero drift on all four
plus the reference targets requires:

- Demo_app: probably clean (small, hand-written tests, 0
  doctests, 0 properties).
- plug_crypto: 1 doctest module — risk if the oracle's doctest
  name encoding diverges from ExUnit's at all.
- nimble_options: macro-heavy, doctests for schema docs. Risk
  surface large.
- jason: property tests. Almost certainly produces drift.

Three of four targets carry plausible drift vectors before any
implementation work begins. The spike's strict kill criterion
("any drift kills it") would fire at the first measurement.

## Decision

**Recommendation: shelve M32. Do not implement affected-test
selection in v1.12.**

Reasoning:
1. The strict kill criterion almost certainly fires on jason
   (property tests) and likely fires on nimble_options (macro
   coverage gaps). Pre-implementation analysis already identifies
   these vectors.
2. The implementation cost (~300–500 LOC + fixtures + new
   coverage-collection paths + ExUnit plumbing) is non-trivial.
   Spending it on a feature whose acceptance gate likely won't
   pass is poor scope.
3. The current `coverage_with_static_fallback` already gives a
   real fanout reduction with a *softer* correctness contract
   (static fallback for any mutant the coverage oracle missed).
   The marginal win of intra-file selection is small relative to
   the engineering cost.

## Reopening criteria

M32 should be revisited if:

- A concrete user report shows `static` selection running tests
  that contribute >50% of mutation-testing wall on a real project
  AND the user is willing to opt in despite the silent-survivor
  risk (i.e. they want a `--selection affected_tests_unsafe` flag
  for experimentation).
- An upstream `:cover` change provides per-test granularity
  attribution natively, eliminating risk vectors 4 and 5.
- An ExUnit feature lands that exposes inter-test dependencies
  (eliminating risk vector 1) — unlikely.

In each case, the strict kill criterion stays — silent-survivor
regression is not acceptable, only the implementation cost shifts.

## What this spike did NOT do

- No bench measurement: implementation cost would have to land
  before measurement, and the spike's pre-implementation analysis
  identifies enough risk vectors to recommend shelving.
- No prototype `--selection affected_tests` flag: same reason.

## Artifacts

- This document.
- No code changes.
- No bench result files.

The `coverage_with_static_fallback` mode remains v1.11's selection
default. v1.12+ may revisit the per-test granularity question if
the reopening criteria above are met.
