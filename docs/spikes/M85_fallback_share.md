# M85 — Fallback wall-clock share spike

**Date:** 2026-05-28
**Verdict: REDIRECT M86.** Fallback is meaningful (35–43% of worker wall) but
v1.8's non-dominant verdict still roughly holds, **and the dominant fallback
constituents — guards and pattern literals — are not schema-routable by AST
shape.** The remaining schema-routable fallback work targets opt-in mutators
absent from the default plan, so the default-plan wall-clock win from
M86-as-scoped would be ≈ zero.

## Measurement (default plan, `--selection static --concurrency 1`, capped at 60 mutants)

### plug (v1.16.1) — total worker wall ≈ 103.7 s

| phase | ms |
|---|--:|
| schema_workers | 59 105 |
| fallback_workers | 44 644 |
| schema_build | 4 233 |
| oracle_build | 4 140 |
| baseline_tests | 1 104 |
| total | 113 551 |

**Fallback worker share: 43.0%** of (schema_workers + fallback_workers).
Per-mutant duration totals (engine column from the `mutalisk.engine` map):

| mutator | n | wall_ms | % of total | engine split |
|---|--:|--:|--:|---|
| Boolean | 12 | 17 729 | 18.7% | schema 12 |
| AtomLiteral | 9 | 17 415 | 18.4% | schema 8, fallback 1 |
| **IntegerLiteral** | 9 | 15 838 | **16.7%** | **fallback 9** (all pattern-position) |
| Arithmetic | 10 | 14 739 | 15.6% | schema 10 |
| **GuardTypeTest** | 6 | 12 407 | **13.1%** | **fallback 6** |
| **GuardComparisonBoundary** | 3 | 5 385 | **5.7%** | **fallback 3** |
| Pin | 2 | 3 535 | 3.7% | fallback 2 |
| ComparisonNegation | 4 | 3 388 | 3.6% | schema 3, fallback 1 |
| ConcatOperator | 1 | 1 639 | 1.7% | schema 1 |
| GuardComparisonNegation | 2 | 1 492 | 1.6% | fallback 2 |
| UnaryNot | 2 | 1 118 | 1.2% | mixed |

Fallback wall totals: schema 54 165 ms / fallback 40 520 ms.

### decimal (78ff0410…) — total worker wall ≈ 94.8 s

| phase | ms |
|---|--:|
| schema_workers | 61 101 |
| fallback_workers | 33 678 |
| schema_build | 3 291 |
| oracle_build | 3 148 |
| baseline_tests | 976 |
| total | 102 378 |

**Fallback worker share: 35.5%.** Top fallback mutators:

| mutator | n | wall_ms | engine |
|---|--:|--:|---|
| **GuardComparisonBoundary** | 4 | 10 215 | fallback 4 |
| **GuardTypeTest** | 3 | 6 675 | fallback 3 |
| **GuardComparisonNegation** | 3 | 4 983 | fallback 3 |
| **IntegerLiteral** | 2 | 3 286 | fallback 2 |
| (others mostly schema; full table in run data) |

## Why M86's premise doesn't hold

The dominant fallback constituents — **guards (~30–40% of fallback) and
pattern-position literals (~30–40% on plug)** — are intrinsically
fallback-routed:

- **Guards.** v1.8's wrapper-guard-schemata rejection (documented at the time,
  16 releases old) was about exactly this: schema instrumentation wraps an
  expression in a runtime `case active do … end`; guard expressions are a
  restricted context (`when` clauses) that does not admit a `case` form. The
  rewrite to make it admit one is the v1.8-rejected workaround. Catalogue
  growth has not changed this AST-shape constraint.
- **Pattern literals.** Patterns are compile-time matches, not expressions —
  there is no runtime `case` to wrap them in. M53 routes pattern literals
  through fallback by design; M52 only schema-routed body-position literals.
  This is structural, not an optimization target.

The schema-routable opt-in mutators (`NegateConditional`, `StatementDelete`)
are absent from the default plan. Routing them would help opt-in workloads but
deliver effectively zero wall-clock savings on the default-plan runs M86 was
scoped around.

## Recommendation

**Redirect M86's budget** rather than ship a schema-routing change whose data
predicts ≈ zero default-plan benefit. Two concrete redirections both make
sense; pick one (M86 commit message records the choice):

1. **Incremental cross-run history prelude** — wire the per-mutant wall-clock
   capture (already in `mutalisk.phase_timings` + per-mutant `duration`) into
   an explicit "previous-run" comparison artifact that v1.25's incremental
   work can consume. Pure data plumbing, no risk to existing IDs, useful
   regardless of which v1.25 incremental design wins.
2. **Reduce schema-build overhead** — schema_build_ms is 4 s on plug and
   3 s on decimal (4% of wall). Cheap if a low-hanging optimization exists
   (e.g. cache the parsed AST per file across the oracle and schema walks);
   no AST-shape constraints in the way.

`bench/results/m85/` keeps the raw per-mutator measurements; M86's commit
references this doc and picks the redirection.

## What this spike does NOT change

The opt-in mutator routing decisions stand (M73 Pin fallback / M77
NegateConditional fallback / M81 StatementDelete fallback). Those are correct
for their AST shapes; the wall-clock cost of fallback is well-understood and
within the M62 graduation budget when they clear it.
