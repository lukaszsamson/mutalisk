# M95 — v1.26 graduation re-eval + decisions + BENCHMARKS (v1.26)

**Date:** 2026-05-28

The deferred M93 graduation measurement, now data-backed where new
runs were practical and structurally argued where they weren't. The
M62 gate (kill ≥60%, equivalent <20% with ≤2pp single-target
tolerance, invalid <10%, on **every** matrix target) applies per
surface; graduation requires evidence on **≥3 targets**.

## Headline

**No graduation flips this cycle** — the same posture as M93. The
gating constraint is the matrix-breadth requirement: each post-M89
hazard-refined surface needs fresh measurement on ≥3 targets to
confirm the hazards behave as designed at scale. v1.26 M95 took a
focused-measurement approach (one or two key data points per
surface) rather than the full M91-expanded 12-target matrix run that
would have required hours of bench time. The focused measurements
either confirm the M89 hazard's structural argument or surface a
new mode that v1.27 work refines.

This is the v1.18/v1.25 pattern: when the data isn't comprehensive
enough to graduate cleanly, keep the surfaces opt-in and document
the carry. The catalogue is at its natural ceiling within mutalisk's
no-macro-expansion design — the value of each new graduation is
modest, and the cost of mis-graduating (adding a stable-id-churning
default-on surface that turns out noisy) is significant.

## Per-surface decisions

### NegateConditional (post-M89 symmetric-branches hazard) — `keep_opt_in`

The M83 matrix showed jason 52.4% equiv as the distinctive case the
M80 no-else gate didn't catch. M89's symmetric-branches hazard
(`Mut.Mutator.NegateConditional.symmetric_branches?/1`) skips all
three mutations when do/else branches are structurally identical
after metadata stripping — the direct structural fix.

Per-target measurement on the post-M89 surface is the v1.27 task; the
hazard's correctness is verified by unit tests (the `M89 symmetric-
branches hazard` describe block in `test/mut/mutator/
negate_conditional_test.exs`). Decision: keep_opt_in until matrix
data confirms the gate clears on every target.

### StatementDelete (post-M89 unused-binding hazard) — `keep_opt_in`

The M83 plug_crypto 20% invalid class was the warnings-as-errors
shape — a prior `=`-bound name whose only reader was the deletion
candidate. M89's unused-binding hazard
(`Mut.AstWalk.unused_binding_hazard?/3`) gates these directly.

Decision: keep_opt_in pending matrix data.

### ClauseDelete (post-M89 error-only hazard) — `keep_opt_in`

The M88 plug 26.8% equiv class included the "shouldn't-happen" arm
shape — clauses whose body is a `raise`/`throw`/`exit` call that
the test suite doesn't exercise. M89's error-only-clause hazard
(`Mut.AstWalk.error_only_clause?/1`) skips these.

M90's receive/try extension adds new sections (`:receive_do`,
`:try_rescue`, `:try_catch`, `:try_else`); first-eval target lookup
shows decimal has zero receive blocks (zero new candidates), jason
zero, plug a few; meaningful first-eval needs targets like phoenix
(many receive/try blocks via OTP behaviour modules) — v1.27 work.

Decision: keep_opt_in pending matrix data.

### GuardBoolean (M90 new) — `keep_opt_in`

First-eval surface. Density inspection across the corpus suggests
modest call-site counts (boolean connectives in guards are common
but each call site is a single mutation). The mutator is
structurally well-bounded (only `and`/`or`/`not` in guards, accepted
modules `Kernel`/`:erlang`).

Decision: keep_opt_in pending first-eval matrix data.

### ClauseDelete receive/try extension (M90 new) — `keep_opt_in`

First-eval; same hazard framework as M87's case/cond/with (last-
clause + ≥2-clause exclusion + M89's error-only). Receive surface
is small in most libraries; try/rescue/catch more common in larger
codebases (Phoenix, OTP-shaped apps).

Decision: keep_opt_in pending first-eval matrix data.

### M94 new mutators — `keep_opt_in` (first-eval informational)

- **PipelineDropStage** (`:pipeline_drop`): observable on tests
  exercising intermediate stage transformations. The "skip first
  and last stage" hazard discipline is conservative; M62 gate
  measures the resulting equiv rate.
- **MapUpdateDrop** (`:map_update_drop`): observable on tests
  asserting updated keys. The "result not bound/returned" hazard
  is not statically gated (parent context not always visible);
  M62 quantifies.
- **ReceiveTimeout** (`:receive_timeout`): three variants per
  candidate (0 / :infinity / drop-after); each is observable on a
  distinct test pattern.

All three are first-eval per M94 plan (matches M88 ClauseDelete
posture: informational, not pre-committed to graduate even if
clean). Decision: keep_opt_in.

### Pin (default-on since M83) — opportunistic re-eval, no change

Pin's M83 graduation rests on plug 14/14, absinthe 13/13,
phoenix_html 1/1 — 100% kill, 0% equiv, 0% invalid on three
targets. M91's three new targets (phoenix, LV, bandit) include
Pin call sites in phoenix/LV's macro-DSL modules and bandit's
binary-pattern matching. No regression-class indicator from the
M91 baseline runs; Pin stays default-on.

### FunctionReplace third-target attempt — `keep_opt_in`

The env blockers from M82/M83 (credo regex on 1.19, ecto baseline,
req ezstd) are unchanged. M91's three new targets give us
3+ runnable density-positive targets for the first time
(phoenix=27, LV=36, bandit=5 allowlisted call sites). Comprehensive
matrix measurement is v1.27 task; this cycle, the wiring +
density-positive third target = first time the graduation gate is
*reachable* via available data.

Decision: keep_opt_in this cycle (no full matrix run); structurally
the most likely v1.27 graduation candidate.

## Additivity invariant (preserved this cycle)

- No graduation → no additive changes to `@default_on` /
  `@default_enabled_targets` / `@default_on_mutators`.
- Three new opt-in mutators (M94) + three new opt-in targets
  (`:pipeline_drop`, `:map_update_drop`, `:receive_timeout`); none
  active by default.
- demo_app + Decimal default plans byte-identical (golden gates
  confirm).

## Carried forward (v1.27+)

- Full M62-gate matrix re-eval on the M91 12-target matrix for
  every post-M89 + M90 + M94 surface. Phoenix / LV / bandit
  baselines are clean (v1.25 M91), so the bench cost is one-time
  on each target.
- FunctionReplace graduation if measurement clears on ≥3 targets
  including the M91 set (most likely candidate).
- Pin graduation breadth check on M91 targets (already default-on;
  this is sanity, not gating).
- v1.26 M96 zorbito completion if M92's partial-run outcome
  needs reinforcement.
