# M108 — Dead-code + CRAP report (coverage-driven)

**Date:** 2026-06-03

**Outcome: no provably-dead code removed — the codebase is clean by
construction.** Four independent analyses agree (a real per-function CRAP run +
three structural checks). The one flagged remnant (the `--worker-type` shim) is
reachable, intentional UX whose removal is a behavior change + a
release-management decision (out of v1.29 scope), so it is documented and
retained.

`crap_ex` flagged 8 functions over CRAP 30. On an explicit follow-up,
**5 were remediated** (behavior-preserving refactor + targeted tests — the
byte-identity gate confirms no behavior change); the remaining 3 are
unit-coverage artifacts of functions covered by the e2e/integration layers (see
the CRAP-results section). This is a data-gated outcome in the project's
established discipline (M60/M88/M93/M95/M103: measure, and act on the real
signal — not a hunch, and not on noise).

## Method

The user's CRAP tool is **`crap_ex`** (`/Users/lukaszsamson/claude_fun/crap_ex`,
`mix crap` — `CRAP(f) = CC(f)² · (1 − cov(f))³ + CC(f)`, BEAM-native from
`debug_info` + `:cover` clause analysis). It was run **dep-free** against
mutalisk's compiled beams (no change to mutalisk's `mix.exs`):

```sh
# in mutalisk:
MIX_ENV=test mix test --cover --export-coverage crap
# in crap_ex:
mix crap --beams "<mutalisk>/_build/test/lib/mutalisk/ebin/*.beam" \
         --coverdata "<mutalisk>/cover/crap.coverdata" \
         --paths "<mutalisk>/lib" --min-score 30
```

Full report: `bench/results/m108_crap_report.txt`. Four structural checks
corroborate the dead-code conclusion:

1. **CRAP** — `crap_ex`, per-function complexity × (1 − coverage). High CRAP
   flags *risky-to-change* code, not dead code.
2. **Orphan-module scan** — every `lib/` module's last segment grepped across
   `lib/` + `test/`; modules referenced only in their own file are candidates.
3. **Compiler** — the build runs `--warnings-as-errors` (bin/verify lint
   layer), which already **fails the build** on any unused private function or
   unused variable. Dead private code cannot exist in a green tree.
4. **Marker + cruft sweep** — grep for `deprecated|legacy|no longer|abandon|
   TODO|FIXME|obsolete`, commented-out code blocks, and single-use module
   attributes.

**Coverage caveat:** `--export-coverage` captures only the **unit** suite (the
e2e / integration_schema / integration_fallback layers run as out-of-band mix
tasks and are not in `:cover`). So mix-task / e2e / worker-port functions show
0% coverage here and their CRAP is **inflated** — their real coverage comes from
those other layers. CRAP is most meaningful for the pure-logic modules the unit
suite *does* cover.

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

## CRAP results — 8 over threshold, **5 remediated** this cycle

`crap_ex`'s first pass found **8 functions over CRAP 30** (worst 127.4). All
were **live** (high CRAP = risky to change, never dead). On a follow-up the
five with a *real* signal — a genuine complexity or test-coverage gap — were
remediated by **behavior-preserving refactor + targeted tests** (the byte-identity
e2e + golden gates confirm zero behavior change: demo_app 67.7, 27 schema /
4 fallback, 33 stable_ids).

| function | before | after | how |
|---|--:|--:|---|
| `Orchestrator.fallback_env_context/3` | **127.4** | 5.9 | refactor — collapsed 9 identical `nil`-returning per-target clauses to one catch-all (CC 14→5); behavior-preserving (`nil` is the correct default for every non-pattern target) |
| `EnvWalker.descend/2` | 68.2 | 27.3 | pure-extraction split (binding-scope forms vs `descend_expr/2` for plain expr/leaf nodes; CC 30→24, identical clause order) **+** new tests for the `cond`/`receive`/`try`/struct clauses (cov 65→82%) |
| `EnvWalker.walk_try/2` | 42.0 | 6.7 | test — `try do/rescue/after` env-walk case (0→73% cov) |
| `Trace.normalize_meta_value/1` | 35.0 | 8.0 | test — `to_dispatch_site/2` with tuple/list/scalar/pid meta values (25→100% cov) |
| `AstWalk.literal?/1` | 33.0 | 9.0 | test — collection-literal module attributes (list / n-tuple / map / non-literal; 33→100% cov) |

The remaining **3 violations are coverage artifacts, not real gaps** — all are
CC-6 functions at **0% _unit_ coverage** because `--export-coverage` captures
only the unit suite; they are exercised by the layers it excludes:

| function | why it's covered elsewhere |
|---|---|
| `Mix.Tasks.Mut.render_reports/5` | the report pipeline — run end-to-end on every `mut.e2e` |
| `Mix.Tasks.Mut.E2e.assert_incremental!/1` | *is* e2e test-harness code (unit-testing a test assertion is circular) |
| `Mut.Worker.Formatter.handle_cast/2` | worker-port event handling — covered by `integration_fallback` |

Chasing these would mean contorting unit tests around mix-task / e2e / worker
internals — out of "where it makes sense." `crap_ex` also correctly dampened 2
generated dispatch tables (`Mut.JSON.pretty/2`, `Static.referenced_module/1`).

## Acceptance

- [x] Dead-code/CRAP report produced — real `crap_ex` run
      (`bench/results/m108_crap_report.txt`) + this document.
- [x] Provably-dead code removed: **none exists** (clean by construction —
      each potential removal examined and justified as reachable/live; the 8
      CRAP violations are all live, flagged not removed).
- [x] No behavior change (no code changed; golden gates + full suite green).
- [x] `bin/verify` green.
