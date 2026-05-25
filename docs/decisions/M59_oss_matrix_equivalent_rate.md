# M59 — OSS matrix completion + equivalent-rate characterization

**Date:** 2026-05-25
**Goal:** produce the per-mutator-per-target data M60 (surface graduation) and
M61 (coverage default) depend on.

## Matrix: 8 / 10 targets ran

Config: `--selection <coverage|static> --max-mutants 1500 --enable
pattern_literal,variable --mutators variable_replace,variable_to_literal,
atom_literal,integer_literal,string_literal,boolean_literal,nil_literal`.
Pinned SHAs (`bench/run.sh`). Stryker JSONs in `bench/results/m59/`.

| target | selection | invalid | errors | notes |
|---|---|---:|---:|---|
| decimal | coverage | 0 | 0 | clean; strong suite (91.6% kill) |
| jason | coverage | 18 (1.2%) | 3 | |
| ecto | coverage | 10 (0.7%) | 173 | macro-heavy codegen errors |
| plug | coverage | 2 | 28 | |
| makeup | coverage | 0 | 31 | weak suite (35.9% kill) — equiv inflated |
| gettext | static | 0 | 48 | coverage-incompatible (see below) |
| credo | static | 50 (3.3%) | 0 | coverage-incompatible; was ~40% pre-fix |
| timex | static | 0 | 1 | coverage-incompatible (tzdata+JIT); 6 µs-drift tests excluded |
| req | — BLOCKED | — | — | ezstd native build; removal cascades to baseline fails |
| oban | — BLOCKED | — | — | Postgres+MySQL+SQLite infra; MySQL absent |

credo's invalid fell ~40% → 3.3% across the v1.17/M57/M58 fixes (Mix.start,
codegen-skip, pipe/capture, default-arg). Errors fell sharply on gettext/plug
(M57). Both confirm the hardening held.

## Equivalent-rate (heuristic: covered survivors)

`bench/equivalent_rate.exs` — equivalent-ish := a SURVIVED mutant COVERED by ≥1
test (the suite runs the code but cannot kill it: true-equivalent OR weak
assertion, indistinguishable syntactically → **over-estimate**). Only the 5
coverage-capable targets yield it:

| mutator | decimal | jason | ecto | plug | makeup |
|---|---:|---:|---:|---:|---:|
| VariableReplace | 9.0% | 22.6% | 39.2% | 33.7% | 62.1%* |
| AtomLiteral (pattern) | 16.7% | — | 25.0% | 20.6% | — |
| IntegerLiteral (pattern) | 5.6% | 0% | 21.1% | 15.6% | 0% |
| NilLiteral (pattern) | — | — | 29.6% | 33.3% | 66.7%* |
| StringLiteral (pattern) | 0% | 50%* | 0% | 13.3% | 100%* |
| BooleanLiteral (pattern) | — | 33%* | 27.3% | 14.3% | 100%* |
| VariableToLiteral | 1.6% | 39.7% | 37.5% | 48.2% | 100%* |

\* makeup has a weak suite (35.9% kill) and several tiny samples (n≤6) — its
high rates reflect weak assertions / small n, not true equivalence; weight the
strong-suite targets (decimal/jason/ecto/plug).

## Coverage selection is NOT robust (key M61 finding)

Coverage collection **failed outright on 3 of 8 targets**:
- **gettext** — `backend_test` compiles a backend at test time; ParallelCompiler
  under `:cover` raises "cannot spawn parallel compiler task".
- **credo** — test timeout (60 s) under `:cover` instrumentation (slow tests).
- **timex** — tzdata network-update during a test + a BEAM JIT assertion crash
  under `:cover`.
(plus a transient `:enoent` mix-spawn on plug, recovered on retry.)

These are coverage-runner robustness gaps on real projects — coverage cannot be
made the default until they are addressed. Direct input to M61.

## Hand-off

- M60: the per-target equivalent-rate above is the graduation gate (M25/M41:
  kill ≥ 60%, **equivalent < 20%**, invalid < 10%).
- M61: coverage's 3/8 failure rate is the robustness evidence.
