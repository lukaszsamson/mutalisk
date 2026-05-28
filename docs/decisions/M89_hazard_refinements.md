# M89 — Hazard refinements + e2e flake fix (v1.25)

**Date:** 2026-05-28

Goal: bundle the v1.24 carries that block graduation, plus the small
e2e_mut flake from v1.24. No graduation flips here — M93 decides those,
data-driven, after the hazards are measured on the wider matrix (M91).

## Hazards added

### NegateConditional — symmetric-branches hazard

The jason equivalence class M83 documented (52.4% equiv, with M80's
no-else gate already in place) was structurally distinct from the
no-else dead-branch shape — both branches *exist* but compute the same
observable. When `if cond do A else B end` has `A ≡ B` (structurally
identical after metadata stripping), every mutation we'd emit is
equivalent to the original:

- `negate` still picks A (since A is what either branch yields).
- `force true` picks A.
- `force false` picks A.

Skip all three. Implementation: `Mut.Mutator.NegateConditional.symmetric_branches?/1`
strips metadata recursively and compares the `:do` and `:else` values.
Conservative: only fires when `:else` exists (no-else handled by M80's
dead-branch gate).

### StatementDelete — unused-binding hazard

The plug_crypto 20% invalid class M83 documented is the analog of M81's
orphan-binding hazard, in the other direction:

- **orphan-binding (M81)**: deleted stmt binds X, later reads X → undefined.
- **unused-binding (M89)**: prior stmt binds X, deleted stmt is its only
  reader → `mix compile --warnings-as-errors` fires "variable X is
  unused".

Implementation in `Mut.AstWalk.unused_binding_hazard?/3`: collect prior
`=`-LHS bindings; if any are read in the deletion candidate but not in
any later statement, gate.

### ClauseDelete — error-only clauses hazard

The plug 26.8% equiv class M88 documented is "covered-equivalent clauses
the suite rarely hits." The clean shape: clauses whose body is a single
`raise`/`throw`/`exit` call (or a block ending in one) — the idiomatic
"shouldn't-happen" arms. If the test suite never matches the clause,
deleting it changes nothing observable.

Implementation in `Mut.AstWalk.error_only_clause?/1`: skip clauses whose
last body statement (or sole body expression) is `raise`/`throw`/`exit`.

## e2e_mut downgraded_to_static flake

Root cause: `Mut.E2e.assert_coverage_non_regression!/2` strictly required
`selection["mode"] == "coverage_with_static_fallback"`, but the M64
pathological-coverage path overrides the requested mode to
`:downgraded_to_static` whenever coverage wall_ms exceeds the 10s floor.
On demo_app's tiny suite (`baseline_tests_ms * 2` is small, so the
floor dominates), occasional sandbox jitter pushed coverage collection
past 10s — the system correctly engaged M64's fallback (its design
purpose), but the assertion treated this as failure.

Fix: accept either `"coverage_with_static_fallback"` or
`"downgraded_to_static"` as a valid post-run mode. The stable-id set
drift check immediately above (`if static_set != coverage_set`) already
protects correctness in either mode — that's the meaningful invariant.
The downgrade is now logged as "M64 fallback engaged" so it's visible
when it happens but isn't a verify failure.

This is a guard, not a root-cause fix of the underlying jitter; the
floor of 10s is calibrated for production-scale suites and is correct
there. A demo_app-only floor adjustment would be more invasive and
hides the M64 mechanism we want exercised.

## FunctionReplace third-target attempt

The M82/M83-documented env blockers are unchanged:

- **credo**: regex compile error in
  `lib/credo/check/config_comment_finder.ex` under Elixir 1.19 — credo's
  bug, not mutalisk's. Newer credo unreleased.
- **ecto**: 9 baseline test failures (env-dependent — no postgres
  adapter in this sandbox).
- **req**: `ezstd` native dependency fails to compile (M55 zstd C build
  blocker).

Tried no new target this cycle. The graduation is M91-gated — Phoenix /
phoenix_live_view both have many `Enum.min`↔`max`, filter↔reject etc.
call sites by density inspection and would be the natural third target
once wired. M93 re-evaluates.

## Acceptance

- All 31 mutator unit tests for the touched surfaces pass.
- Full unit suite green (451 tests, 0 failures).
- Golden gates green (18 tests, 0 failures) — zero stable-id churn on
  demo_app, as expected: the new hazards only filter candidates that
  would either be invalid (warnings-as-errors class) or equivalent
  (error-only arms); demo_app's golden plan exercises neither shape.
- Per-surface equivalence/invalid measurement before/after deferred to
  M93's matrix run (the OSS surfaces actually carrying the load).
