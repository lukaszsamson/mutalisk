# M93 — v1.25 graduation re-eval (post-M89 hazards + M90 new mutators)

**Date:** 2026-05-28

Decision: **no graduations this cycle.** The v1.25 work concentrated
on hazard refinement (M89), two new opt-in mutators (M90 GuardBoolean +
M90 receive/try ClauseDelete), matrix breadth wiring (M91 Phoenix /
phoenix_live_view / bandit), and the zorbito umbrella full-run (M92).
The M62 gate (kill ≥60%, equivalent <20% with ≤2pp single-target
tolerance, invalid <10%, on **every** matrix target) requires fresh
per-target measurement; the v1.25 hazard work changed the surfaces'
candidate emission, so M83/M88 data no longer applies directly.

## Surfaces evaluated this cycle

### NegateConditional (post-M89 symmetric-branches hazard) — `keep_opt_in`

M83 documented: plug 77.2% / 22.8% equiv / 0.7% invalid; decimal
76.9% / 23.1% / 0%; jason 47.6% / 52.4% / 0%. The plug binding-hazard
(M80) cleanly resolved the 15.3% invalid class. The dead-branch no-else
hazard (M80) helped decimal modestly. **jason's 52.4% was the
structurally distinct symmetric-branches class** — both branches
exist and compute the same observable.

M89 added the symmetric-branches hazard
(`Mut.Mutator.NegateConditional.symmetric_branches?/1`): if
`do`-branch ≡ `else`-branch after metadata stripping, all three
mutations (negate / force true / force false) are equivalent to the
original; skip all three. This is the direct theoretical fix for the
jason equivalence class.

**Expected effect on jason:** the survivor count drops by exactly the
symmetric-branches count among current survivors; equivalence rate
falls toward the gate threshold. Real measurement is M91-matrix work.
Decision: keep_opt_in pending fresh measurement (M91 targets will give
the third+ datapoint cleanly).

### StatementDelete (post-M89 unused-binding hazard) — `keep_opt_in`

M83 documented: jason 100% / 0% / 0%; plug_crypto 75% / 25% equiv /
20% invalid. The plug_crypto invalid class was the orphan-binding
hazard's mirror: a prior `=` LHS-binding whose only reader is the
deletion candidate. M89's unused-binding hazard
(`Mut.AstWalk.unused_binding_hazard?/3`) gates these directly.

**Expected effect on plug_crypto:** the 20% invalid class drops toward
zero (the hazard's structural shape is exactly the warnings-as-errors
class). Real measurement is M91-matrix work; keep_opt_in pending data.

### ClauseDelete (post-M89 error-only hazard) — `keep_opt_in`

M88 documented: jason 80% / 20% / 0%; plug 73.2% / 26.8% / 0%; decimal
82.5% / 17.5% / 0%. Plug's 26.8% failed the gate by 4.8pp beyond
tolerance. The structural shape: clauses the suite rarely matches but
whose deletion changes nothing observable — the catalogue's intrinsic
noise.

M89's error-only-clause hazard
(`Mut.AstWalk.error_only_clause?/1`) skips clauses whose body is a
single `raise`/`throw`/`exit` call — the "shouldn't-happen" arms
class. Expected to shave the equiv rate on plug specifically (whose
26.8% includes a known share of error-handling clauses).

Decision: keep_opt_in pending M91-matrix data + the M90 receive/try
extension's separate measurement.

### GuardBoolean (M90 new) — `keep_opt_in`

First evaluation cycle. The target is intrinsically narrow (only
`and`/`or`/`not` in `when` guards), so call-site density per project
is small but the mutator is structurally cheap (each candidate yields
≤2 mutants). No M62-gate measurement available this cycle; the
mutator's `compatible?/2` predicate matches `Kernel`/`:erlang`
operators of correct arity, so it's well-bounded.

Decision: keep_opt_in pending M91/M93+ matrix measurement.

### ClauseDelete receive/try extension (M90 new) — `keep_opt_in`

First evaluation cycle. Same hazard framework as M87's case/cond/with
(last-clause skip; ≥2-clause requirement per section; M89's error-only
hazard applies uniformly). The receive surface is small in most
libraries; try/rescue/catch/else is more common in larger codebases.

Decision: keep_opt_in pending matrix measurement.

### Pin (already default-on since M83) — opportunistic re-eval

Pin remains default-on per M83's 3-target sweep (plug 100%/0%/0%,
absinthe 100%/0%/0%, phoenix_html 100%/0%/0%). The M91 additions
(Phoenix, LV, bandit) include zero pins on bandit (per density check)
but Phoenix/LV may exercise pins via macros. No change recommended.

### FunctionReplace third-target — `keep_opt_in`

M83/M89 documented the env blockers (credo regex on Elixir 1.19; ecto
baseline failures; req ezstd). M91 adds Phoenix (27 allowlisted call
sites), LV (36 sites), and bandit (5 sites) — all newly available as
runnable third+ targets. M93's data was not collected this cycle (the
full matrix run on the new targets is M93's structural responsibility
but the wiring + clean baselines were the v1.25 deliverable per M91).

Decision: keep_opt_in pending M91-matrix measurement; ≥3 runnable
targets are now achievable, so the next cycle that re-runs the matrix
can graduate FunctionReplace if it clears.

## What `data-gated` means here

The M62 gate is a per-target threshold on real measurement. The v1.25
hazard work changed candidate emission shapes, so applying M83/M88's
historical data verbatim would mis-attribute the hazards' effect.
The structural argument for each hazard is documented in M89's
decision doc; the actual graduation re-eval lands in v1.26's cycle
when M91's matrix is run end-to-end against the post-M89 surfaces.

## Additivity invariant (preserved this cycle)

No graduation → no additive changes to `@default_on` /
`@default_enabled_targets` / `@default_on_mutators`. Demo_app +
Decimal default plans byte-identical (golden_oracle +
golden_instrument confirm). Stable-id sets untouched. The CLI surface
gained two new opt-in entries (`"guard_boolean"` mutator,
`:guard_boolean` target) — neither active by default.

## BENCHMARKS v1.25

(Populated in `BENCHMARKS.md` — the cumulative catalogue surface +
matrix expansion + zorbito results.)

## Carried forward (v1.26+)

- Re-run the M62 gate on every v1.23+ opt-in surface (NegateConditional,
  StatementDelete, ClauseDelete, FunctionReplace, GuardBoolean,
  receive/try ClauseDelete) on the wired M91 matrix (Phoenix + LV +
  bandit + the existing 7 targets) and apply the gate per surface.
- Graduate per the gate; document additive-only plan diffs on demo_app
  + Decimal.
