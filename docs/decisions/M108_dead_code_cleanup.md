# M108 — Dead-code + CRAP report (coverage-driven)

**Date:** 2026-06-03

**Outcome: no provably-dead code removed — the codebase is clean by
construction.** Four independent analyses agree. The one flagged remnant (the
`--worker-type` deprecation shim) is reachable, intentional UX whose removal is
a behavior change + a release-management decision (out of v1.29 scope), so it is
documented and retained. High-CRAP-but-live modules are flagged informationally
(M108 explicitly scopes out refactoring them). This is a data-gated outcome in
the project's established discipline (M60/M88/M93/M95/M103: measure, and don't
act on a hunch).

## Method

`ex_crap` (the user's CRAP tool) is **not present in this environment**, so per
the PLAN's fallback this used coverage-report-driven dead-code detection, plus
three corroborating structural checks:

1. **Coverage** — `mix test --cover` (unit suite), per-module line coverage.
2. **Orphan-module scan** — every `lib/` module's last segment grepped across
   `lib/` + `test/`; modules referenced only in their own file are candidates.
3. **Compiler** — the build runs `--warnings-as-errors` (bin/verify lint
   layer), which already **fails the build** on any unused private function or
   unused variable. Dead private code cannot exist in a green tree.
4. **Marker + cruft sweep** — grep for `deprecated|legacy|no longer|abandon|
   TODO|FIXME|obsolete`, commented-out code blocks, and single-use module
   attributes.

## Findings

### No dead modules

The orphan scan surfaced only four "orphans", all `Mix.Tasks.*`:
`Mix.Tasks.Compile.MutOracle`, `Mix.Tasks.Mut.TestSchema`,
`Mix.Tasks.Mut.TestFallback`, `Mix.Tasks.Mut.E2e`. These are **invoked by CLI
name**, not by code reference (`mix compile.mut_oracle`, `mix mut.test_schema`,
`mix mut.test_fallback`, `mix mut.e2e` — all run by `bin/verify`). Reachable,
not dead.

### No dead private code

Guaranteed by `--warnings-as-errors`: an unused private helper or variable
fails the build. The tree is green, so none exist.

### Zero-coverage modules are all reachable integration/CLI surfaces

`mix test --cover` (unit suite only) reported 0.00% for the mix-task entry
points (`Mix.Tasks.Mut` and friends), `Mut.MemoryWatchdog`, the
`JSON.Encoder` protocol impl, and the `Mutalisk` runtime-API façade. These are
exercised by the **e2e + integration_schema + integration_fallback** layers
(which `--cover` did not include), not by unit tests. Their real coverage is
non-zero; the 0% is an artifact of measuring only the unit layer. Spot-checks
of suspicious-looking public functions (`FileCopy.{copy_tree,cow_copy,
plain_copy}`, `TestRuntime.from_formatter_output`) confirmed every one is a live
module-qualified call site.

### No commented-out code, no unused attributes

The marker sweep found only legitimate prose (comments *about* handling
unused-variable churn — `statement_delete`, `pin`, `variable_replace`,
`ast_walk` — not dead code). Every single-use module attribute is a directive
(`@enforce_keys`, `@derive`, `@dialyzer`, `@typedoc`) correctly used once.

### The one remnant: `--worker-type` deprecation shim (retained)

`Mut.Cli.worker_type/2` is a deprecated no-op surviving the v1.15/M42
persistent-worker removal: `--worker-type mix` warns once and proceeds; any
other value is rejected with a pointed error. The PLAN flagged it as the known
leftover.

**Retained, deliberately.** It is (a) **reachable** — a user with an old flag or
`config :mut, worker_type:` hits it, so it is not *provably dead*, which M108
scopes as the only thing removable; (b) **intentional UX** — a graceful
deprecation that guides migration, not leftover cruft; (c) **behavior-bearing** —
removing it turns `--worker-type mix` into an "unknown option" error, a behavior
change that M108's acceptance ("no behavior change") forbids. Retiring a
deprecation path is a release-management decision (a future major version),
which is itself out of v1.29 scope (the release-management hold still applies).

### `bench/cross_run.exs` (M86 redirect prelude) — retained

The read-only cross-run delta script. v1.29 (M105–M107) shipped the *in-engine*
reuse feature, but `cross_run.exs` remains a **functionally distinct, working**
standalone tool (it diffs two Stryker reports for human inspection — a different
capability from reuse). Not dead; kept.

## High-CRAP-but-live (informational — NOT changed this cycle)

CRAP ≈ complexity × (1 − coverage)². The modules with the most
complexity-under-low-unit-coverage are **test/refactor candidates**, not dead
code; M108 explicitly scopes out touching live high-CRAP code. Flagged for a
future cycle:

| module | unit cov | note |
|---|--:|---|
| `Mut.CompileRollback` | 8% | exercised mainly via fallback-recompile integration; thin unit coverage |
| `Mut.Worker` | 55% | core execution/classification; integration-covered, unit-light |
| `Mut.Mutator.IntegerLiteral` | 19% | graduated mutator; add unit cases for its pattern paths |
| `Mut.Oracle` | 52% | dispatch resolution; integration-covered |

These are flags, not work items — adding targeted unit tests (not rewrites) is
the right future follow-up.

## Acceptance

- [x] Dead-code/CRAP report produced (this document).
- [x] Provably-dead code removed: **none exists** (clean by construction —
      each potential removal examined and justified as reachable/live).
- [x] No behavior change (no code changed; golden gates + full suite green).
- [x] `bin/verify` green.
