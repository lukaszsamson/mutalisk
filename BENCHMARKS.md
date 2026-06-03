# Mutalisk Benchmarks

## v1.30 incremental floor — skip instrumentation for reused mutants (M109, 2026-06-03)

Under `--incremental`, the reuse partition now runs *before* schema build, so
reused mutants are pruned from instrumentation (only to-be-executed mutants get
schema gates). Verdicts + score are provably unchanged (M107 harness passes;
decimal 80.0 == 80.0, 89/90 reused; demo_app 67.7, 31 reused / 0 executed).

| decimal (cap 100) | instruments | schema build | total |
|---|--:|--:|--:|
| cold (full) | ~90 | 2974 ms | 148.0 s |
| warm `--incremental` (M109) | ~11 | 2913 ms | 15.3 s |

**Finding:** instrumentation count drops to executed-only as designed, but the
schema-build time barely moves (2974 → 2913 ms) — SchemaPlacer *placement* is a
~60 ms sliver of a compile-dominated phase. The 148 s → 15.3 s total is the
M106 *execution* savings; M109's additional contribution is small. The residual
incremental floor is the work-copy **`mix compile`** + fixed phases (oracle
build, baseline, coverage), not instrumentation. Next lever (future): caching
the compiled work copy / skipping schema build for reused-only runs.
`docs/decisions/M109_incremental_floor.md`.

## v1.29 incremental cross-run history (M104–M107, 2026-06-03)

The long-deferred v2 perf bet, shipped opt-in (`--incremental`). A warm run
adopts a stored verdict for any mutant whose enclosing-function source and
selected-test content are unchanged (M104 function-level digests), and only
the remainder re-executes. The trust gate (M107) proved reuse never changes
the answer.

**Ground-truth (full vs `--incremental`, unchanged tree — verdicts must match):**

| target | mutants | cold score | warm score | verdicts identical | reused / executed |
|---|--:|--:|--:|:--:|--:|
| demo_app (e2e, CI-locked) | 31 | 67.7 | 67.7 | yes | 31 / 0 |
| decimal (`--max-mutants 100`) | 100 | 80.0 | 80.0 | yes | 89 / 1 |

**Wall-clock (warm run on an unchanged tree):**

| target | mutants | cold (full) | warm (`--incremental`) | speedup |
|---|--:|--:|--:|--:|
| demo_app | 31 | 15.7 s | 9.3 s | 1.69× |
| decimal | 100 | 156 s | 16 s | **≈9.75×** |

The win scales with mutant count: demo_app is fixed-overhead-bound (oracle +
schema build + baseline + coverage dominate 31 tiny mutants); decimal is
execution-bound, so reuse collapses 156 s → 16 s. The 16 s floor is the
fixed-phase cost (the schema build still instruments all mutants — reused ones
aren't skipped there yet; future optimization).

**Source-change invalidation (`bench/m107_incremental_validation.exs`,
properties PASS):** a semantics-preserving edit to one source file invalidates
**all** reuse (executed 31/31, reused 0) and warm verdicts still equal a fresh
full run — no stale verdict slips through.

> **Correction (2026-06-03 review).** An earlier version of this section claimed
> *diff-scoped* reuse (edit one function → re-execute only its 7 mutants). That
> was **unsound** — Mutalisk doesn't track cross-file dependencies, so a mutant
> calling a changed helper would reuse a stale verdict. The reuse key now
> carries a coarse **project fingerprint** (all source + test-support + config +
> deps), so any source change invalidates everything. Reuse benefits the
> unchanged-tree re-run; dependency-aware diff-scoping is future work. See
> `docs/decisions/incremental_reuse_soundness.md`.

Decision + CI-usage guide: `docs/decisions/M107_incremental_history.md`.
Evidence reports: `bench/results/decimal.incremental.{cold,warm}.json`.

## v1.27 close the catalogue-validation arc (M97–M98, 2026-06-02)

The arc-closer. After two releases of "data-gated, no flips" deferred on
session-envelope grounds, M97 **built the sharding harness** and actually
ran the matrix — producing the headline graduation the breadth-blocked
prior cycles couldn't reach.

### M97 sharded matrix — FunctionReplace GRADUATES

**The sharding strategy.** `bench/shard_matrix.sh`: shard = one target,
clone + deps + compile **once** into a persistent `tmp/bench/shard/<target>`
(`.shard_ready` flag → re-runs skip to mutation), then loop each surface
as a focused `mix mut --enable <flag> --mutators <name> --max-mutants N`
against the compiled work_copy. The expensive clone/compile is paid once
per target instead of once per cell. Remaining bottleneck: per-surface
coverage re-collection on large suites (bandit's 653-test `:cover` pass
~8 min/surface) — handled with `timeout 900` + a `--selection static`
escape where the covered-survivor metric isn't the gating question.

**FunctionReplace → default-on** (4th new graduation since M46, after
IntegerLiteral-in-pattern M63, ConcatOperator M79, Pin M83):

| target | n | kill% | equiv% | invalid% | source |
|---|--:|--:|--:|--:|---|
| plug | 13 | 100 | 0 | 0 | M79 |
| absinthe | 27 | 83.3 | 16.7 | 0 | M82 |
| bandit | 9 | 88.9 | 11.1 | 0 | **M97 (fresh, the unblocking 3rd target)** |

All clear the M62 gate. The recurring "needs a third runnable target"
blocker (kept it opt-in M79/M83/M88/M95 *for lack of breadth*, never
quality) is gone — M91's bandit wiring supplied it. Additive +
byte-identical: demo_app has zero allowlisted call sites, Decimal `fr`
is n=0 (golden gates green).

**Everything else stays keep_opt_in — now with real measured data:**

| surface | decimal | jason | bandit | verdict |
|---|---|---|---|---|
| NegateConditional | 76.9/23.1/0 | 47.6/52.4/0 | — | jason **unchanged** vs M83 — M89 symmetric-branches hazard addresses a different shape than jason's observational-equivalence class |
| StatementDelete | 100/0/0 (n=1) | 100/0/0 (n=6) | — | clean but tiny-n; the M83 20%-invalid target (plug_crypto) unmeasured (coverage-slow) — keep_opt_in |
| ClauseDelete | 87.5/12.5/0 | 77.8/22.2/0 | — | M89 error-only helped decimal (17.5→12.5) but jason 22.2% + plug 26.8% (M88) fail |
| GuardBoolean | n=0 | n=0 | n=0 | **practically-empty surface** — boolean-op guards are rare (comparison/type-test dominate, already covered) |
| PipelineDropStage | 100/0/0 (n=2) | 100/0/**66.7** (n=3) | — | jason **66.7% invalid** — dropping a stage breaks downstream output-type expectations (invalid-hazard carry) |
| MapUpdateDrop | 50/**50**/0 | 100/0/0 (n=2) | — | decimal 50% equiv confirms the ungated "result-unused" noise from M94 |
| ReceiveTimeout | n=0 | n=0 | 55.6/44.4/0 (**18 err**) | noisy on real concurrent code (timeout mutations → crashes/hangs, not clean kills) |
| Pin | n=0 | n=0 | — | stays default-on (M83); no regression |

(Format kill%/equiv%/invalid%; `n=0` = no candidates on that target.)
Full per-surface rationale in `docs/decisions/M97_graduation_matrix.md`.

### M98 zorbito retry

**The M96 compile block is resolved** — the user's btc_scanner refactor
landed; `mix compile` now succeeds across all 14 apps. The bounded
mutation run was blocked at the baseline by **live-instance resource
occupancy**: the user's running zorbito dev instance (`iex -S mix
phx.server`) holds the umbrella's metrics/ranch ports (`:eaddrinuse`
on `:prometheus_metrics`) and DB connection pool, so mutalisk's baseline
can't start the apps. This is an environment-occupancy block (Postgres
is up, the code compiles) — not a mutalisk defect, and I didn't disrupt
the user's live services to force it. Umbrella validation closes at the
engine-proven state (v1.20 M67/M68 + v1.21 M74 unilink real full run +
M71/M92 zorbito oracle+schema); the only remaining step is operational —
run when the dev instance is stopped. See
`docs/decisions/M98_zorbito_completion.md`.

## v1.26 close-out + niche mutators (M94–M96, 2026-05-28)

Three milestones: M94 ships three new niche mutators, M95 applies the
M62 gate to the comprehensive surface (post-M89 hazard-refined +
M90 first-eval + M94 first-eval + opportunistic Pin/FunctionReplace
re-eval), M96 finishes the zorbito umbrella run M92 started.

**No graduation flips this cycle.** Same posture as M93 — the gating
constraint is matrix breadth. M95 took a focused-measurement approach
(decimal opt-in surfaces) rather than the full 12-target run; the
data confirms the M89 hazards work as designed on decimal but
graduation requires ≥3-target evidence on each surface, which the
v1.27+ work delivers.

### M94 niche mutators

Three opt-in fallback-routed mutators, each behind its own opt-in
target (so default plan stays unchanged):

- **`Mut.Mutator.PipelineDropStage`** (`:pipeline_drop`): drop a
  middle stage from a `|>` chain. Skips first (destroys input),
  last (refactoring-equivalent), and chains shorter than 3 stages.
  Custom span: leftmost leaf to rightmost call's `:closing`.
- **`Mut.Mutator.MapUpdateDrop`** (`:map_update_drop`): `%{m | k: v}`
  → `m`. Only mutates the update-syntax shape; plain `%{a: 1}`
  literals skipped.
- **`Mut.Mutator.ReceiveTimeout`** (`:receive_timeout`): three
  mutations per candidate — `t` -> `0` (immediate), `t` ->
  `:infinity` (never), drop the `after` clause. Receives without
  `after` skipped.

21 unit tests pass. demo_app byte-identical (golden gates).

### M95 measurement + decisions

Same posture as M93. The post-M89 hazard-refined surfaces
(NegateConditional, StatementDelete, ClauseDelete), the M90 first-eval
surfaces (GuardBoolean, receive/try ClauseDelete), and the M94 first-
eval surfaces (PipelineDropStage, MapUpdateDrop, ReceiveTimeout) all
stay `keep_opt_in` — fresh matrix data on the M91 12-target set is
the gating constraint, deferred to v1.27.

Pin stays default-on per M83 (no regression-class indicator from M91
baselines). FunctionReplace third-target attempt: the M91 wiring
(phoenix 27 / LV 36 / bandit 5 allowlisted call sites) is the first
time the gate is *reachable* via available data — also v1.27 work.

The catalogue is at its natural ceiling within mutalisk's no-macro-
expansion design; v1.27+ is comprehensive-matrix-data work, not new
mutator work.

See `docs/decisions/M95_graduation_matrix.md`.

### M96 zorbito completion

See `docs/decisions/M96_zorbito_completion.md`.

## v1.25 catalogue maturation + matrix breadth + zorbito (M89–M93, 2026-05-28)

v1.25 ships the bundled v1.24 carries that block graduation plus two
new opt-in mutators and the long-deferred wider OSS matrix breadth.
**No graduation flips this cycle** — M93 is honestly data-gated: the
M89 hazard work changed candidate emission shapes, so M83/M88 data no
longer applies directly; fresh matrix measurement on the post-M89
surfaces lands in v1.26 with M91's three new targets available.

### M89 hazard refinements + e2e_mut downgrade-tolerance

- **NegateConditional symmetric-branches hazard.** Skip all three
  mutations (negate / force true / force false) when both branches
  are structurally identical after metadata stripping. The direct
  theoretical fix for jason's 52.4% equiv class from M83 — both
  branches compute the same observable, so every mutation is
  observationally equivalent to the original.
- **StatementDelete unused-binding hazard.** Skip deletion when a
  prior `=` LHS-bound name is read only by the deletion candidate
  (no later reader) — `mix compile --warnings-as-errors` fires the
  "unused variable" warning, the Invalid class on plug_crypto (20%
  in M83).
- **ClauseDelete error-only-clause hazard.** Skip clauses whose body
  is a single `raise`/`throw`/`exit` (or a block ending in one) —
  the idiomatic "shouldn't-happen" arms; rare test exercise drives
  the covered-equivalent class behind plug 26.8% in M88.
- **e2e_mut flake guard.** Accept either `coverage_with_static_fallback`
  or `downgraded_to_static` as a valid post-run mode; M64's pathology
  fallback is the engine working as designed (a sandbox-jitter race,
  not a defect); the stable-id drift check immediately above already
  protects correctness in either mode.

Expected effect (per-hazard structural argument): jason equiv drops
toward the gate; plug_crypto invalid drops toward 0%; plug ClauseDelete
equiv shaves. **Measurement deferred** to v1.26's M93+ matrix run.

### M90 new mutators

- **`Mut.Mutator.GuardBoolean`**: `and`<->`or` swap; `not x` -> `x`
  drop, inside `when` guards. Closes the gap left by Guard{Comparison,
  TypeTest}. Opt-in via dedicated `:guard_boolean` target (NOT
  `:guard`, which is in `@default_enabled_targets` — using a fresh
  target preserves the default-plan surface).
- **`Mut.Mutator.ClauseDelete` extension**: case/cond/with (M87) +
  receive (`:do` clauses; `:after` not touched) + try (`:rescue`,
  `:catch`, `:else` independently; `:after` not touched). Same M87
  hazard framework (last-clause skip, ≥2-clause requirement); M89's
  error-only hazard applies uniformly to all new sections.

19 ClauseDelete unit tests pass (the original case/cond/with paths
+ receive + try sections + error-only hazard); 7 GuardBoolean unit
tests pass; full unit suite 465 / 0; golden gates 18 / 0. demo_app
byte-identical: the new opt-in target gating + the absence of
receive/try constructs in the fixture mean zero stable-id churn.

### M91 wider OSS matrix

Three new bench targets wired in `bench/run.sh`:

- **phoenix v1.8.1** (1046 tests, 0 failures, ~25s). FunctionReplace=27,
  NegCond=hundreds, Case=87. Tests in-process via plug_cowboy.
- **phoenix_live_view v1.0.2** (1223 tests, 0 failures, 3 :env_drift
  excluded). FunctionReplace=36 (densest of the untried corpus); heavy
  macro DSL exercises M78 codegen-context exclusion.
- **bandit 1.8.0** (653 tests, 0 failures, :slow + :otp_ssl_cipher_drift
  excluded; preserves bandit's own :slow gate so h2spec docker + autobahn
  fuzzer remain out-of-band). FunctionReplace=5, ~43 NegCond, ~87 case.

Each clean-baseline so the v1.26+ matrix run won't waste cycles on
baseline drift triage. Wiring + clean baselines is the v1.25 M91
deliverable; full mutation runs are M93+ work.

### M92 zorbito umbrella full worker run

The 14-app crypto umbrella was engine-validated in v1.21 (M71: 150k
sites, schema 0 invalid). v1.25 closes the umbrella validation story
properly: mutalisk wired into zorbito's `mix.exs` deps, baseline
gated (2 env-specific failures tagged `:env_drift` — BTC block parser
fixture drift, BTC node-ping HTTP mock — analogous to ecto / timex
drift skips). Bounded `mix mut --max-mutants 30 --selection static`
run exercises oracle → schema build → worker dispatch → fallback on
real umbrella code. The 2090+ baseline tests across 14 apps with
multi-DB + RabbitMQ + clustering setup are clean post-tag-skip.

The bounded mode follows v1.21 M74's unilink precedent: structural
validation (engine pathway works on real umbrella) without
committing to the full ~150k-site mutation budget.

### M93 graduation re-eval — no flips this cycle

- **NegateConditional, StatementDelete, ClauseDelete**: keep_opt_in
  (post-M89 hazard work changed candidate emission; fresh matrix
  measurement pending).
- **GuardBoolean, ClauseDelete receive/try**: keep_opt_in (first
  evaluation; no matrix data this cycle).
- **FunctionReplace third target**: keep_opt_in (env blockers unchanged
  from M83; M91's new targets provide the third datapoint, measured
  in v1.26).
- **Pin**: stays default-on per M83's 3-target sweep.

No `@default_on` / `@default_enabled_targets` / `@default_on_mutators`
changes → zero stable-id churn → demo_app + Decimal default plans
byte-identical (verified via golden_oracle + golden_instrument).

## v1.24 reliability + measurement-redirected perf + ClauseDelete (M84–M88, 2026-05-28)

### M84 BEAM-startup retry

Defensive retry-on-transient in `Mut.ChildProcess.run` (new `:retry_on` +
`:max_retries`), wired from `Mut.Recompile.recompile` for the three v1.23-
observed BEAM-startup signatures (`"Failed to load module 'elixir'"` /
`"Runtime terminating during boot"` / `"Crash dump"`). Never retries on
success or on arbitrary failure (would mask real bugs). The flake did not
reproduce in isolation (parallel `elixir --eval` storms at c=8 / c=32 ran
clean over 80-storm iterations), so the fix is the defensive layer rather
than a root-cause repro.

### M85 fallback-share spike

Default plan, `--selection static --concurrency 1 --max-mutants 60`:

| target | schema_workers_ms | fallback_workers_ms | total_ms | fallback share |
|---|--:|--:|--:|--:|
| plug | 59 105 | 44 644 | 113 551 | **43.0%** |
| decimal | 61 101 | 33 678 | 102 378 | 35.5% |

Dominant fallback contributors are intrinsically not schema-routable
(guard `when` clauses don't admit a runtime `case` wrap — v1.8's verdict
holds; pattern literals are compile-time matches with no runtime wrap).
Verdict: **redirect M86**. See `docs/spikes/M85_fallback_share.md` +
`bench/results/m85/per_mutator_wall.txt`.

### M86 redirected → cross-run delta tool

Per the M85 spike, schema-routing-as-scoped would have ≈ zero default-plan
benefit. M86 redirects to `bench/cross_run.exs` — a pure analysis tool
that takes two Stryker JSON reports and emits score delta + status
transitions + stable-id sets + per-mutator wall delta. Foundation for
v1.25's incremental cross-run history candidate.

### M87 ClauseDelete (new opt-in)

`Mut.Mutator.ClauseDelete` — case / cond / with(`else`) clause removal.
Opt-in `:clause_delete`, fallback-routed. Hazards filtered in the
collector: last-clause excluded (case/cond catch-all), `true ->`
excluded (cond fallback), with `<-` chain skipped, with single-`else`
skipped.

### M88 graduation re-eval

| target | n | kill% | equiv% | invalid% |
|---|--:|--:|--:|--:|
| jason | 45 | 80.0 | 20.0 | 0.0 |
| plug | 175 | 73.2 | 26.8 | 0.0 |
| decimal | 58 | 82.5 | 17.5 | 0.0 |

**ClauseDelete → keep_opt_in.** 0% invalid everywhere (M87 hazards work
cleanly); kill 73–83% comfortably clears the ≥60% bar; **plug equiv 26.8%
fails** even with the ≤2pp single-target tolerance (admits ≤22%). The
miss is structural (covered-but-suite-equivalent — deletion of a clause
the tests rarely hit), not a quality defect. See
`docs/decisions/M88_clause_delete.md`. NegateConditional / StatementDelete
re-eval not triggered (M86 redirected; their routing characteristics
unchanged). FunctionReplace third-target blockers from M82 still in place.

## v1.23 close the queue (M80–M83, 2026-05-28)

NegateConditional hazards, statement-deletion (M81), matrix breadth (M82),
and the data-gated re-eval (M83). **Pin graduated to default-on** (3rd
graduation since M46; second this year after M79's ConcatOperator).

### M80 NegateConditional hazards (before → after)

| target | invalid before | invalid after |
|---|---:|---:|
| plug | 15.3% | **0.7%** |
| decimal | 0% | 0% |

Binding hazard (`if x = lookup(), …`) caught plug's dominant invalid class.
Dead-branch hazard (no-else `if`/`unless`) helped decimal modestly
(equiv 25.4%→23.1%); jason's equiv stayed at 52% (its surviving mutants
are both-branch-equivalent, not no-else).

### M81 StatementDelete (new)

`Mut.Mutator.StatementDelete` — delete a non-last `def` body statement;
fallback-routed (whole-def span re-render). Hazard-gated up front: body
position only (collector visits defmodule → def directly); last statement
excluded; orphan-binding hazard skips deletions whose bound name is read
later. Smoke: `_ = log(); x+1` mutant killed by `assert_received`;
`sum = x+y; sum*2` skipped (orphan).

### M82 matrix breadth

Wired **absinthe** (pinned v1.7.10) into `bench/run.sh`: pins=17, allowlisted
calls=54, standalone (deps = nimble_parsec + telemetry). Pin now exercised
on **3 targets** (plug, absinthe, phoenix_html). FunctionReplace stayed at
2; every other candidate hit an env blocker (credo's regex incompatibility
on Elixir 1.19; ecto's 9 baseline failures; req's ezstd; small targets had
no allowlisted call sites). See `bench/results/m82/summary.txt`.

### M83 graduation matrix

| target | mutator | n | kill% | equiv% | invalid% |
|---|---|--:|--:|--:|--:|
| plug | Pin | 14 | 100 | 0 | 0 |
| absinthe | Pin | 13 | 100 | 0 | 0 |
| phoenix_html | Pin | 1 | 100 | 0 | 0 |
| plug | FunctionReplace | 13 | 100 | 0 | 0 |
| absinthe | FunctionReplace | 27 | 83.3 | 16.7 | 0 |
| plug | NegateConditional | 138 | 77.2 | 22.8 | 0.7 |
| decimal | NegateConditional | 67 | 76.9 | 23.1 | 0 |
| jason | NegateConditional | 23 | 47.6 | 52.4 | 0 |
| jason | StatementDelete | 6 | 100 | 0 | 0 |
| plug_crypto | StatementDelete | 5 | 75 | 25 | 20 |

- **Pin → GRADUATED default-on.** Three matrix targets, **100% kill / 0%
  equiv / 0% invalid everywhere**. Additive: Decimal default plan unchanged
  at 559 mutants (no pins to add); demo_app byte-identical. Wiring: Pin
  moves to `@default_on` (+ `@default_on_mutators` mirror); `:pattern_shape`
  joins `@default_enabled_targets`.
- **FunctionReplace → keep_opt_in.** Clean on both targets it exercises, but
  M82 could only reach two — the gate's "≥3 targets each clear" misses
  on target-availability, not mutator quality.
- **NegateConditional → keep_opt_in.** M80's binding hazard cut plug
  invalid 15.3%→0.7%, but equiv >20% on 3 of 4 targets.
- **StatementDelete → keep_opt_in.** plug_crypto 20% invalid + 25% equiv;
  intrinsically the catalogue's noisiest, the M81 hazards are necessary but
  not yet sufficient.

See `docs/decisions/M83_graduation_matrix.md`.

## v1.22 catalogue growth: the two missing classics (M76–M79, 2026-05-27)

Two new mutators (FunctionReplace, NegateConditional) + two carries
(ConcatOperator codegen exclusion, Pin re-eval). M79 coverage matrix
(equivalent = covered-survivors), M62 gate:

| target | mutator | n | kill% | equiv% | invalid% |
|---|---|--:|--:|--:|--:|
| jason | ConcatOperator | 1 | 100 | 0 | 0 |
| plug | ConcatOperator | 13 | 100 | 0 | 0 |
| decimal | ConcatOperator | 10 | 90 | 10 | 0 |
| plug | FunctionReplace | 13 | 100 | 0 | 0 |
| plug | Pin | 14 | 100 | 0 | 0 |
| plug | NegateConditional | 189 | 99.3 | 0.7 | 15.3 |
| decimal | NegateConditional | 69 | 74.6 | 25.4 | 0 |
| jason | NegateConditional | 27 | 48 | 52 | 0 |
| plug_crypto | NegateConditional | 12 | 50 | 50 | 0 |

- **ConcatOperator → GRADUATED default-on** (first since M63): clears every
  target (kill ≥90%, equiv ≤10%, 0% invalid) after M72's direction-drop + M78's
  codegen exclusion (jason 67%→0% equiv). Additive: Decimal +10, 0 existing IDs
  changed; demo_app byte-identical.
- **FunctionReplace / Pin → keep_opt_in**: flawless on plug (100% kill, 0%
  equiv/invalid) but single-target — leading candidates, need breadth.
- **NegateConditional → keep_opt_in**: high dead-branch equivalence (jason 52%,
  decimal 25%, plug_crypto 50%) + 15.3% invalid on plug. High-yield, too noisy
  to default-on yet.

See `docs/decisions/M79_graduation_matrix.md`.

## v1.21 close the v1.20 deferrals (M72–M75, 2026-05-26)

### M72 operator hazard rules (before → after, non-productive rate)

| mutator | change | result |
|---|---|---|
| ConcatOperator | drop `--`→`++` (crash-prone) | jason non-productive **67% → 0%** (9 mutants → 3) |
| BitwiseOperator | drop `bor`↔`bxor` (pseudo-equiv) | plug_crypto pseudo-equiv survivors 2 → 1 |

### M73 Pin (pattern-shape, opt-in) + M75 map-key hazard

`^x` → `x` unpin. M75 found map-key pins (`%{^k => v}`) are unpinnable
(compile error) → excluded; Pin invalid **~30% → 0%** on real code (plug/jason).

### M74 umbrella validation

- unilink: real full `mix mut` (5 apps, live Postgres+RabbitMQ) — valid multi-app
  report across all 5 apps, 5/24 killed, fallback 2/10 killed, **0 errors**, 1 invalid.
- zorbito: engine path across **14 apps** — oracle 150,083 sites, plan 1882 mutants,
  schema build 0 invalid. Full worker run blocked on crypto-chain infra (not gating).

### M75 graduation matrix (coverage; equivalent = covered-survivors) — all keep_opt_in

| target | mutator | n | kill% | equiv% | invalid% |
|---|---|--:|--:|--:|--:|
| jason | ConcatOperator | 3 | 33.3 | 66.7 | 0 |
| plug | ConcatOperator | 13 | 100 | 0 | 0 |
| decimal | ConcatOperator | 10 | 90 | 10 | 0 |
| plug | Membership | 8 | 100 | 0 | 0 |
| plug_crypto | BitwiseOperator | 1 | 0 | 100 | 0 |
| plug | Pin | 14 | 100 | 0 | 0 |

0% invalid everywhere (hardening worked). None clears the M62 gate on *every*
target: ConcatOperator fails jason (codegen survivors); Bitwise/Membership thin
+ pseudo-equivalent on jason; **Pin is flawless on plug but only one target has
unpinnable pins** → leading graduation candidate, deferred for multi-target data.
See `docs/decisions/M75_graduation_matrix.md`.

## v1.20 umbrella support + catalogue growth (M66–M71, 2026-05-25)

### Umbrella engine on `~/unilink` (5 apps)

| phase | result |
|---|---|
| oracle | 89 518 dispatch sites, app-prefixed across 5 apps (no `lib/` collisions) |
| plan (default) | 1031 mutants spanning all 5 apps (772 schema / 259 fallback) |
| schema build | instruments `apps/<app>/lib`, compiles instrumented umbrella, per-app ebin snapshot |
| cross-app fallback | hub mutant `Unilink.Model.PlatformClient` → 93 deps across all 5 apps; one-pass recompile, beams routed per-app (verified), source reset OK |

Full `mix mut` worker+report validated on a self-contained 2-app umbrella:
`8/9 killed, 0 invalid, 0 errors`, report spans both apps. (unilink's own
worker run is gated on its Postgres/RabbitMQ test infra.) Single-app path
byte-identical (golden_oracle + golden_instrument green).

### M69 operator-expansion mutators (opt-in) — graduation data

| target | mutator | killed | survived | invalid | error |
|---|---|---:|---:|---:|---:|
| plug_crypto | BitwiseOperator | 0 | 2 | 0 | 0 |
| jason | ConcatOperator | 1 | 2 | 2 | 4 |
| jason | Membership | 0 | 1 | 0 | 0 |

ConcatOperator noisy on real list/binary code (`++`→`--` → compile errors
in refused/macro positions + suite-aborting runtime crashes, ≈67% of 9);
BitwiseOperator yields input-dependent pseudo-equivalents; Membership
cleanest. **Decision: keep_opt_in** (see `docs/decisions/M71_*`); M70
pattern-shape mutators **cut to v1.21**.

## v1.19 finish the stalled flips (M62–M65, 2026-05-25)

### M63 — IntegerLiteral-in-pattern graduated (additive)

Default plan, Decimal: gains **18 IntegerLiteral (pattern) mutants**; all other
mutators unchanged (Arithmetic 202, AtomLiteral 75, …), existing IDs untouched.
demo_app default plan byte-identical (no integer patterns). Clears the M62
sharpened gate (decimal 5.6% / plug 15.6% / ecto 21.1% equivalent — single
≤2pp miss).

### M65 — coverage default: kill-count parity + wall-clock

decimal, default plan, static vs coverage_with_static_fallback:

| selection | killed | score | wall |
|---|---:|---:|---:|
| static | 385 | 80.9% | 240 s |
| coverage (run 2) | 385 | 80.9% | 247 s |

Kill counts match (a run-1 384 was `decimal.ex:432` test flakiness — killed on
re-run). Coverage adds a ~6 s collection pass; on fast suites this offsets the
per-mutant fanout savings (≈neutral), so the win is on slow suites. gettext now
**completes** under coverage (M64 degrades `backend_test`) where it aborted in
M61.

## v1.18 maturation (M57–M59, 2026-05-25)

### M59 — OSS matrix (8/10) + per-mutator equivalent-rate

8 of 10 targets ran (req/oban environment-blocked; timex needed 6 µs-drift
tests excluded). Config: `--enable pattern_literal,variable` + the literal +
variable mutators, capped 1500, coverage where the runner allows (else static).
Per-mutator **equivalent-rate** = covered-survivors / (Killed+Survived), an
over-estimate (conflates weak-assertion with true equivalence). Full data:
`docs/decisions/M59_oss_matrix_equivalent_rate.md`, `bench/results/m59/`.

**Equivalent-rate vs the M25/M41 graduation bar (< 20%):**

| mutator | decimal | jason | ecto | plug | verdict |
|---|---:|---:|---:|---:|---|
| VariableReplace | 9.0% | 22.6% | 39.2% | 33.7% | fails 3/4 → no graduate |
| pattern AtomLiteral | 16.7% | — | 25.0% | 20.6% | fails ecto/plug |
| pattern IntegerLiteral | 5.6% | 0% | 21.1% | 15.6% | fails ecto |
| pattern Nil/Boolean | — | — | 27–30% | 14–33% | fails ecto/plug |
| VariableToLiteral | 1.6% | 39.7% | 37.5% | 48.2% | fails 3/4 |

No surface clears < 20% on every meaningful target → **M60 graduates nothing**
(stays opt-in; revisit later).

**Coverage selection robustness:** failed outright on 3/8 targets — gettext
(compile-in-test under `:cover`), credo (test timeout), timex (tzdata + BEAM JIT
crash). → **M61 cannot make coverage the default**; static stays default.

### M57 — variable error tail (refinement)

| target | errors before (v1.17) | after (M57) |
|---|---:|---:|
| gettext | 211 (27%) | 45 (14.7%) |
| plug | 202 (6%) | 24 (1.6%) |

Codegen-function skip + other-uses gate. credo variable invalid: ~40% → 3.3%
across the v1.17/M57/M58 fixes.

## v1.17 literals-first-class + v2 surface (M52–M55, 2026-05-24)

### M55 — new opt-in surfaces on the OSS subset

`--enable pattern_literal,variable` with the new mutators, pinned SHAs
(`bench/run.sh`). The acceptance bar is **invalid < 10%**.

| Target | shape | total | killed | kill% | **variable invalid** | pattern-lit | errors |
|---|---|---:|---:|---:|---:|---:|---:|
| decimal | math | 835 | 735 | 88.0 | **0.76%** (6/787) | 43/48 | 0 |
| jason | JSON/binary | 2177 | 1531 | 70.3 | **1.25%** (27/2160) | clean | 8 |
| gettext | macro/codegen | 790 | 386 | 48.9 | **0.39%** (3/769) | 11/21 | 211 |
| plug | dispatch/web | 3444 | 2308 | 67.0 | **1.45%** (47/3242) | 158/202 | 202 |

Both new surfaces clear the invalid bar. Variable mutation produces many
**errors** (detections, not false negatives) in codegen-heavy modules
(gettext 27%, plug 6%) — swapping a variable in a function that builds quoted
code breaks dependent compilation. Both stay **opt-in** (see
`docs/decisions/M55_corpus_validation.md`). A bitstring-specifier defect found
here (`<<rest::bits>>` mis-read as a variable) cut jason's variable invalid
rate from 19% → 1.25% (commit `da89799`).

### M52 — schema vs fallback wall-clock (perf verdict)

decimal default plan: a single **2.6 s** instrumented schema build is shared by
all 366 schema mutants (then test-only runs); the fallback engine recompiles
**once per mutant** — ~0.43 s/mutant on decimal's small modules, ~2.1 s/mutant
on plug (7168 s / 3444). Routing the scalar-literal catalogue to schema (M52)
removes a recompile per literal mutant; the literal bucket now rides ~free on
the dispatch schema build. **Verdict: keep literals on schema.**

## v1.16 harvest + harden (M47–M51, 2026-05-23)

### M48 — default-plan delta (AtomLiteral default-on)

AtomLiteral became the first env-walker mutator in the default plan. The
change is purely additive — every non-env-walker stable ID is unchanged;
the default gains exactly the AtomLiteral mutants.

| Target | v1.15 default | v1.16 default | AtomLiteral added | non-env IDs |
|---|---:|---:|---:|---|
| demo_app | 31 | 31 | +0 (no body atoms) | identical |
| plug_crypto v2.1.1 | 64 | 70 | +6 | identical |
| Decimal | 456 | 526 | +70 | identical |
| plug v1.19.1 | 352 | 411 | +59 | identical |

No String/Float/Nil/Collection leaked into any default plan (verified by
plan diff). `--enable …,env_walker` / `--mutators` still produce the
v1.15 plans.

### M50 — CollectionEmpty maps + n-tuples (opt-in), invalid rate

Execution with `--enable env_walker --mutators collection_empty` (now
covering list / 2-tuple / map / n-tuple; struct maps never emptied):

| Target | CollectionEmpty mutants | killed | survived | invalid | kill% | inv% |
|---|---:|---:|---:|---:|---:|---:|
| plug_crypto v2.1.1 | 20 | 17 | 2 | 0 | 89.5 | **0.0** |
| Decimal | 39 | 28 | 11 | 0 | 71.8 | **0.0** |

Invalid rate is 0% on both (well under the <10% gate) — the new map/
n-tuple shapes always compile. Byte-identity held: plug_crypto added
exactly 7 map/n-tuple mutants with every prior CollectionEmpty ID
preserved.

### M47 — reporter robustness

The plug v1.19.1 full literal run (1,390 mutants, all literal mutators
enabled) now writes valid Stryker JSON (schemaVersion 2) end-to-end. In
M46 the same run executed all 1,390 mutants then crashed at the reporting
step (`TokenMissingError` rendering one heredoc-literal diff), losing the
results. Post-fix: zero mutants needed the marker fallback (heredoc cases
degrade cleanly to the unformatted render).

## v1.15 literal execution validation + span fix (M46, 2026-05-23)

First **execution-level** validation of the env-walker literal mutators
(M40/M44/M45 were plan-level only). `mix` worker, `--concurrency 4`,
`--enable dispatch,guard,module_attribute,body_literal,env_walker` with
all literal mutators on.

### The span-correctness fix (and its intentional churn)

Execution surfaced that the env-walker **scalar** literal span covered
~1 character, not the whole literal (the parser's `literal_encoder` drops
`:token` for strings/atoms; the walker fell back to a 1-char span). So
StringLiteral mutated to invalid source (100% CompileError) and
Atom/Nil mutated to garbage-but-compiling values (`:ok→:errorok`). M41
only checked stable-ID *distinctness*, never execution, so it was latent.

`Mut.EnvWalker.literal_span` now scans the source for the true end
(`:token` length for numbers; `:delimiter` scan for strings/quoted atoms;
value length for bare atoms/`nil`). This **intentionally churns** the
stable IDs of StringLiteral / AtomLiteral / NilLiteral — a one-time
correctness migration; those mutators never produced a valid mutant
before. FloatLiteral (`:token`) and CollectionEmpty (`:closing`) already
had correct spans and did not churn; non-literal and AstWalk body-literal
mutants are untouched (default-flag plans verified byte-identical).

### Per-mutator kill / invalid (post-fix)

| Mutator | demo_app | plug_crypto | Decimal | phoenix_html | plug |
|---|---|---|---|---|---|
| StringLiteral table | — | 85.7% k / 0 inv (21) | **26.3%** / 0 (57) | 90.9% / 0 (66) | 87.1% / 0 (351) |
| AtomLiteral | — | 66.7% / 0 (6) | 91.4% / 0 (70) | — | 94.9% / 0 (59) |
| CollectionEmpty | 100% / 0 (1) | 100% / 0 (13) | **69.4%** / 0 (36) | 100% / 0 (36) | 94.3% / 1.5% (196) |
| NilLiteral | — | — | **16.7%** / 0 (6) | 100% / 0 (1) | 100% / 0 (31) |
| FloatLiteral | — | — | 0% / 0 (1) | — | — |

(`k` = kill rate; `inv` = invalid (CompileError) rate; `(n)` = mutant
count. `—` = no body-literal of that kind in the target. Decimal — a
fixed-point library with many non-behavioural data/error-string literals
— is the consistent low outlier, **bold**.) plug's per-mutator counts
were recovered from the streaming log: the Stryker JSON writer hit a
`TokenMissingError` rendering one mutant's diff (a reporter-robustness
bug, tracked for follow-up; orthogonal to the literal validation — all
1390 plug mutants executed).

### Decisions (docs/decisions/M46_*.md)

Decision rule: a `default_on` flip affects every user, so it requires
clearing thresholds on **every meaningful-sample target**, not just the
count-weighted aggregate (which plug's large clean counts would dominate).

| Mutator | Decision | Why |
|---|---|---|
| AtomLiteral | **default_on** | per-target kill 66.7 / 91.4 / 94.9 — all ≥60%; 0 invalid; clears on every target |
| CollectionEmpty | keep_opt_in | aggregate 91.9% but Decimal alone 30.6% survivors (per-target noise) |
| StringLiteral table | keep_opt_in | aggregate 80.5% but Decimal 26.3% kill; prepend-space row equivalent-heavy |
| NilLiteral | keep_opt_in | aggregate 86.8% but Decimal 16.7% kill |
| FloatLiteral | keep_opt_in | n=1, insufficient evidence |

Only AtomLiteral clears `default_on` (the flip itself is bundled with
v1.16 env-walker default-enablement), so the `--enable literal` preset is
deferred (rule requires ≥2). Invalid is ≤1.1% across the corpus post-fix.
env-walker parse+walk stays well under the 10% oracle-wall gate (Decimal
plan_generation 151 ms vs oracle 3064 ms = 4.9%; plug parse+walk 34 ms,
~1% of its multi-second oracle build).

## v1.15 higher-noise literals: atom + collection (M45, 2026-05-23)

Added `AtomLiteral` (closed allowlist) and `CollectionEmpty` (list +
2-tuple; maps / n-tuples deferred to v1.16). Both opt-in.

Byte-identity: with atom/collection disabled, the plan is byte-identical
to M44 on plug_crypto (173 default / 194 env) and Decimal (780 / 844) —
the new candidates become skips, not mutants. Enabling them is purely
additive:

| Target | env (no atom/coll) | + atom/coll | new mutants |
|---|---:|---:|---|
| Decimal | 844 | 950 | +106 (AtomLiteral 70, CollectionEmpty 36) |

All 844 prior env stable IDs preserved. Invalid/equivalent rates are
deferred to M46's execution-level validation.

## v1.15 low-noise literals (M44, 2026-05-23)

Added `FloatLiteral`, `NilLiteral`, and the `StringLiteral` expand_table
(`→ "x"`, prepend-space). All opt-in (`--enable env_walker`).

Byte-identity gate — for each target, the pre-M44 plan stable-id set vs
the post-M44 set, same flags:

| Target | default flags | `--enable env_walker` |
|---|---|---|
| demo_app | identical (33) | n/a (no body literals) |
| plug_crypto v2.1.1 | identical (173) | all 180 preserved, +14 |
| Decimal | identical (780) | all 799 preserved, +38 |
| plug v1.19.1 | identical (753) | all 870 preserved, +234 |
| phoenix_html v4.3.0 | identical (212) | all 234 preserved, +44 |

No existing mutant's stable ID changed on any of the five corpus
targets (the `+N` are the new StringLiteral expand rows). With all
three new mutators enabled, Decimal surfaced 57 StringLiteral, 6
NilLiteral, and 1 FloatLiteral mutants — confirming the float/nil paths
execute end-to-end on real code.

## v1.15 worker-type removal (M42, 2026-05-23)

The opt-in persistent worker was removed in v1.15; `mix` is the
only worker. The persistent-vs-mix comparison rows recorded in
the v1.7–v1.10 sections below are retained as the historical
measurement record that informed the removal decision — they
describe a worker that no longer ships. v1.15 mutation outcomes
(stable-id sets and kill counts) are byte-identical to the v1.14
`mix`-worker runs.

## v1.14 env walker + StringLiteral mutator (M40 + M41, 2026-05-11)

M40 shipped `Mut.EnvWalker` as a fifth candidate source and
`Mut.Mutator.StringLiteral` as the first env-walker-backed
mutator. Both behind opt-in flags
(`--enable env_walker --mutators string_literal`).

M41 ran plan-level byte-identity validation on the M40
acceptance set (demo_app + plug_crypto + Decimal + plug +
phoenix_html). Full decision doc at
`docs/decisions/M41_string_literal_decision.md`.

### Plan-level matrix (5 targets × {default, env_walker enabled})

| Target | Default IDs | env_walker IDs | New IDs | Lost IDs | StringLiteral mutants |
|---|---:|---:|---:|---:|---:|
| demo_app | 31 | 31 | 0 | **0** | 0 |
| plug_crypto v2.1.1 | 64 | 71 | 7 | **0** | 7 |
| Decimal | 456 | 475 | 19 | **0** | 19 |
| plug v1.19.1 | 352 | 469 | 117 | **0** | 117 |
| phoenix_html v4.3.0 | 93 | 115 | 22 | **0** | 22 |

**Stable-ID churn for existing mutants is zero on all five
targets.** M40's binding byte-identity gate holds. Each new
StringLiteral mutant has a unique stable-ID; literal_span
computation falls back to `:end_of_expression` token metadata
when `:token` is unavailable on string literal AST nodes
(JSON-safe ast_path_hash via `Base.encode16` mirrors the M23
walker).

Plan-only validation: no test execution. Kill rates for the
new mutants are operator-driven measurements; M41 records the
mutant surface, not the kill counts.

### Decision

`keep_opt_in`. The mutator stays behind
`--enable env_walker` / `--mutators string_literal` defaults.
Kill-rate evaluation is operator work; M41's plan-level evidence
cannot establish the `expand_table` criteria
(equivalent <20% AND kill ≥60%) without test runs, and the
conservative outcome is consistent with M33 / M37 reframings:
kill rate is a property of the test suite, not the mutator.

### Sidecar observations

- **plug** shows a **33% mutant-surface increase** (352 → 469).
  Real-world surface that users on plug-class projects will
  benefit from when opting in.
- **phoenix_html**'s opaque policy correctly excludes
  `@doc ~S"""...""" ` sigil heredoc bodies — none of the 22 new
  mutants live inside docstrings. The M34 SchemaPlacer closure
  + env walker land cleanly on Phoenix-class targets.
- **Decimal** scales +4% (456 → 475). Smaller proportion than
  plug because most of Decimal's mutation surface is already
  covered by M23 integer-literal / comparison / boolean / guard
  mutators.
- **demo_app** correctly produces zero string mutants (the
  fixture is arithmetic-/comparison-/boolean-only by design).

## v1.12 SchemaPlacer escaped-quote fix (M34, 2026-05-10)

M34 narrowed `Mut.SchemaPlacer.strip_heredoc_delimiters/1` to
match only `:<<>>` interpolated-string AST nodes, leaving sigil
heredocs (`:sigil_S` / `:sigil_s` / etc.) intact. Pre-M34, the
strip applied to all 3-tuple nodes including sigils, which forced
`Macro.to_string/1` into the regular `~S"..."` form for sigil
heredocs — fatal when the body contained literal `"` characters
(would close the sigil prematurely). Three M27-pinned targets
crashed schema build on this; M34 unblocks them.

Re-bench results (replacing the M27 unrunnable rows):

| Target | Combined | Mix score | Persistent score | Drift | Class (post-M34) |
|---|---:|---:|---:|---:|---|
| `phoenix_html` v4.3.0 | 93 mutants | 81.7% | 81.7% | 0 | **clean** |
| `plug` v1.19.1 | 352 mutants | 97.6% | 98.0% | 17 (4.8%) | drift (16 `RuntimeError → Killed` in `lib/plug/router/utils.ex` — supervisor-init class, same mechanism as Ecto/M30) |
| `phoenix_pubsub` v2.2.0 | 113 mutants (mix) | 71.4% | — | — | unrunnable (different cause): persistent boot fails when `test/support/cluster.ex` calls `Mix.State.get/2` from a non-Mix-bootstrapped node. Mutalisk regression closed; test-infra issue out of scope. |

The M27 BENCHMARKS table entries for these three targets are
updated to reflect the post-M34 state.

`bench/M27_RUNBOOK.md` adjusted to note that M34 closed the
SchemaPlacer crash; phoenix_pubsub's residual cluster-test
dependency on `Mix.State` is documented as an unrelated
unrunnable. The persistent boot-warning catalogue is unchanged
— phoenix_pubsub failure is not a project-class signature we
can detect from compiled-dep tree.

## v1.11 OSS harness expansion (M27, 2026-05-10)

M27 widens the permanent OSS validation matrix beyond the 5
M25 targets so v1.11+ default-flip and warm-state decisions
are not anchored on a narrow base. SHAs pinned in `bench/run.sh`;
operator runbook at `bench/M27_RUNBOOK.md`. Drift partitions
produced by `mix mut.drift` (see `Mut.Drift.Bucketer`).

**Mode**: `static` selection at `--concurrency 4`. Body-literal
matrix is NOT re-run (M25 settled it as opt-in; M27 measures
persistent drift on new project shapes only).

| Target | SHA / tag | Schema | Fallback | Total | Mix score | Persistent score | Drift | Bucket | Class |
|---|---|---:|---:|---:|---:|---:|---:|---|---|
| `castore` | `v1.0.9` (`428328b`) | 4 | 2 | 6 | 0.0% | 0.0% | 0 | — | clean |
| `mime` | `v2.0.7` (`4bb1ba1`) | 5 | 0 | 5 | 60.0% | 60.0% | 0 | — | clean |
| `telemetry_metrics` | `v1.1.0` (`138d532`) | 21 | 10 | 31 | 90.3% | 90.3% | 0 | — | clean |
| `mint` | `v1.8.0` (`f697f1c`) | 190 | 60 | 250 | 75.6% | 100.0% | 49 (19.6%) | pool_warm_state ×49 | drift |
| `nimble_pool` | `v1.1.0` (`9829f27`) | 22 | 6 | 28 | 75.0% | 89.3% | 4 (14.3%) | pool_warm_state ×4 | drift |
| `nimble_csv` | `v1.3.0` (`2fc3cbf`) | 0 | 0 | 0 | — | — | — | — | informational (defmacro-heavy, 0 mutants) |
| `gen_stage` | `v1.3.2` (`d1532fa`) | 186 | 91 | 277 | mix-baseline-flake | 85.6% | — | — | informational (mix flaked one timing test) |
| `phoenix_html` | `v4.3.0` (`8cfd3e3`) | 45 | 48 | 93 | 81.7% | 81.7% | 0 | — | clean (post-M34) |
| `plug` | `v1.19.1` (`8723880`) | 225 | 127 | 352 | 97.6% | 98.0% | 17 (4.8%) | supervisor_init ×16 + parse_class ×1 | drift (post-M34, post-M35 bucketer); supervisor-init class on `lib/plug/router/utils.ex` |
| `phoenix_pubsub` | `v2.2.0` (`086e0af`) | 78 | 35 | 113 | 71.4% | — | — | — | unrunnable (post-M34): persistent boot fails when test/support/cluster.ex calls `Mix.State.get/2` on a node where Mix isn't bootstrapped — test-infra issue, NOT a SchemaPlacer crash |
| `finch` | `v0.9.1` (`0530e34`) | — | — | — | — | — | — | — | unrunnable: `:x509` transitive dep fails on Erlang/OTP 28 |
| `ex_machina` | `v2.8.0` (`d1ec5e4`) | — | — | — | — | — | — | — | unrunnable: `:credo` dev dep fails on Elixir 1.19 (regex char-class) |
| `tzdata` | `v1.1.3` (`61fb7ec`) | — | — | — | — | — | — | — | unrunnable: baseline test failures |

**Acceptance summary**: 5 non-unrunnable targets (telemetry_metrics,
mint, nimble_pool, castore, mime) match M27 acceptance "≥5 NEW OSS
targets benched + classified". The remaining pinned-but-unrunnable
targets are kept in the harness so future operators on different
toolchains (older Elixir / OTP / patched x509 / patched credo)
can rerun without re-pinning.

### M30 — Ecto warm-state validation (2026-05-10)

Re-bench of ecto v3.13.6 after `Mut.Worker.PersistentRunner.Reset.reset_ecto/0`
landed:

| | pre-M30 mix | pre-M30 persistent | post-M30 mix | post-M30 persistent |
|---|---:|---:|---:|---:|
| Combined score | 78.0% | 76.0% | 78.0% | 76.5% |
| Drift mutants | — | 226 | — | 231 |

ETS-clearing reset reaches the `Ecto.Query` planner cache but
produces no measurable drift reduction. The dominant warm-state
class is supervisor-init reordering (mix-spawn re-runs
`Application.start/2`; persistent doesn't), which reset hooks
cannot close.

**Decision: classify Ecto-class projects as mix-only.** Reset
hook stays as defense-in-depth. v1.11 default-flip gate STAYS
gated; `--worker-type` default remains `mix`.

| Drift bucket | Pre-M30 | Post-M30 |
|---|---:|---:|
| `RuntimeError → Killed` | 115 | 113 |
| `Survived → Killed` | 62 | 67 |
| `Killed → Survived` | 23 | 22 |
| `RuntimeError → Survived` | 23 | 23 |
| `RuntimeError → CompileError` | 2 | 4 |
| `Killed → CompileError` | 0 | 1 |
| `Timeout → Killed` | 1 | 1 |

### M28 — Mox.Server reset hook validation (2026-05-10)

Re-bench of mox v1.2.0 after `Mut.Worker.PersistentRunner.Reset.reset_mox/0`
landed:

| Mode | Score | Killed | Survived | CompileError | Drift vs mix |
|---|---:|---:|---:|---:|---|
| pre-M28 mix | 86.8% | 33 | 5 | 0 | — |
| pre-M28 persistent | 86.8% | 33 | 0 | 5 | 5 (3 mox_class + 2 parse_class) |
| post-M28 mix | 92.1% | 35 | 3 | 0 | — |
| post-M28 persistent | 100.0% | 36 | 0 | 2 | 5 (3 mox_class + 2 parse_class) |

The drift count is unchanged (5), but the pre/post comparison
reveals the 3 `Survived → Killed` mutants are NOT Mox.Server
state leaks. All 3 are killed by `MoxTest.ClusterTest` tests
that spawn peer Erlang nodes; the residual is cluster/peer-state
drift, not local-node mock-registry state. M28's hook closed the
local-node vector cleanly (no test failures from cumulative
expect/4 calls or stale allowances). The cluster-state residual
is sequenced behind M29's recompile-isolation spike.

The 2 `Killed → CompileError` mutants are persistent's in-process
recompile parser disagreeing with mix-spawn — `:parse_class`,
M29-territory.

(Mix-mode scores diverge from M25's 86.8% baseline because the
test-execution environment changed across runs; mix and persistent
were both re-measured at the same toolchain.)

### v1.11 unsupported patterns (new beyond M25's four)

M27 surfaced two new unsupported-pattern classes documented in
`docs/PERSISTENT_WORKER_GUIDE.md`:

1. **HTTP-client / process-pool warm state.** `mint` v1.8.0 shows
   49/250 mutants where `mix=Survived → persistent=Killed`, all in
   `lib/mint/http2.ex`, `lib/mint/core/transport/ssl.ex`, and
   `lib/mint/http1.ex`. `nimble_pool` v1.1.0 shows 4/28 with the
   same direction. The warm BEAM accumulates socket / pool / worker
   state across mutants; mix-spawn re-creates it per run. The
   `:pool_warm_state` drift bucket auto-classifies this; the
   persistent boot warning does NOT yet detect HTTP-client
   signatures (mox/ecto/gettext only) — adding `mint`/`finch`/
   `nimble_pool` to the boot detector is a v1.12 follow-up.

2. **SchemaPlacer escaped-quote crash.** `phoenix_html`, `plug`,
   and `phoenix_pubsub` all crash schema build with the same
   `Code.format_string!/2 → SyntaxError` shape on source files
   that contain HTML/header content with embedded escaped double
   quotes (`\\"...\\"`). This is a Mutalisk regression NOT specific
   to the persistent worker — both worker types fail identically.
   Tracked as a v1.12 follow-up; placement of the fix is in
   `Mut.SchemaPlacer.render/1`.

### Drift bucketer cross-validation (M25 + M27 data)

`mix mut.drift --all` was run against the combined M25 + M27
results. Per-bucket counts on M25's 5 targets match the
hand-classification documented in v1.10's CHANGELOG:

| Target | Total | Drift | Buckets | Unclassified |
|---|---:|---:|---|---:|
| decimal | 454 | 0 | — | 0% |
| plug_crypto | 64 | 0 | — | 0% |
| mox | 38 | 5 | 3 mox_class + 2 parse_class | 0% |
| nimble_options | 72 | 14 | 11 parse_class + 3 unclassified | 21.4% |
| ecto | 992 | 222 | 162 ecto_warm_state + 59 ecto_false_kill + 1 timeout_flap | 0% |
| jason | 396 | 5 | 1 parse_class + 1 timeout_flap + 3 unclassified | 60% |

Aggregate unclassified rate on the combined M25 + M27 corpus:
**13/300 drifting mutants ≈ 4.3%**. M27's 49+4=53 mint+nimble_pool
drift contributes 0 unclassified (all `pool_warm_state`); jason's
3 unclassified are baseline noise from a 396-mutant corpus where
absolute drift is 5 mutants. Hand-classification at v1.12+ is no
longer required for new targets in M28/M30's class.

## v1.10 validation matrix (M25 final, 2026-05-10)

M25 ran every M24-pinned OSS target at the latest stable SHA
(commit `feff0f9` for the SHA pin) under all four mode combinations
of `{mix, persistent} × {baseline, --enable-body-literal}`.

Targets, pinned SHAs, runnability:

| Target | Pin | Mix | Persistent |
|---|---|---|---|
| `nimble_options` | v1.1.1 | runnable | runnable, drift |
| `mox`            | v1.2.0 | runnable | runnable, drift |
| `jason`          | v1.4.5 | runnable | runnable, drift |
| `ecto`           | v3.13.6 | runnable | runnable, drift |
| `gettext`        | v1.0.2 | runnable | unrunnable (boot crash) |

`gettext` persistent worker fails at boot: `Gettext.Compiler.__before_compile__/1`
calls `Kernel.ParallelCompiler.async/1`, which requires the calling
process to already be running under a parallel-compile context. The
persistent worker's test-load step initializes outside that context.
This is target-class incompatibility; see PERSISTENT_WORKER_GUIDE.

### Mix-mode kill rates (baseline, no body-literal)

| Target | Mutants | Killed | Survived | Errors | Invalid | Kill rate |
|---|---:|---:|---:|---:|---:|---:|
| nimble_options | 72 | 56 | 9 | 3 | 0 | 85.5% |
| mox            | 38 | 32 | 3 | 0 | 0 | 92.1% |
| jason          | 396 | 240 | 101 | 2 | 53 | 70.0% |
| gettext        | 79 | 38 | 28 | 9 | 4 | 56.1% |
| ecto           | 994 | 580 | 273 | 140 | 1 | 70.2% |

`jason`'s 53 invalid are legitimate guard-rewrite mutants the Elixir
compiler rejects (26 GuardComparisonBoundary + 26 GuardComparisonNegation
+ 1 GuardTypeTest). Not persistent drift.

`ecto`'s 140 errors are tests that hit RuntimeError during mix-spawn
mutant runs — mix-spawn surfaces them; persistent's warm-state
reuse hides them (see drift table below).

### Body-literal kill rates (mix mode, IntegerLiteral + BooleanLiteral only)

| Target | Pure mutants | Killed | Survived | Errors | Invalid | Kill rate |
|---|---:|---:|---:|---:|---:|---:|
| nimble_options | 14 | 11 | 1 | 2 | 0 | 78.6% |
| mox | 12 | 9 | 3 | 0 | 0 | 75.0% |
| jason | 346 | 220 | 118 | 8 | 0 | 63.6% |
| gettext | 47 | 21 | 24 | 2 | 0 | 44.7% |
| **Aggregate** | **419** | **261** | **146** | **12** | **0** | **62.3%** |

ecto body_literal mode skipped — the mix-baseline alone took 49
minutes; body_literal mode (~2x mutants) was deferred to keep M25
in budget. The n=419 sample across four other targets is sufficient
for Decision 1 input.

Excluding `jason` (StreamData target — Decision 1 spec excludes
this from the deterministic-targets average): **66.1% mean** across
nimble_options + mox + gettext.

### Byte-identity drift (mix vs persistent at the same body-literal mode)

| Target | Mode | Total | Drift | % |
|---|---|---:|---:|---:|
| nimble_options | baseline | 72 | 14 | 19.4% |
| nimble_options | body_literal | 86 | 19 | 22.1% |
| mox | baseline | 38 | 5 | 13.2% |
| mox | body_literal | 52 | 7 | 13.5% |
| jason | baseline | 396 | 5 | **1.3%** |
| jason | body_literal | 750 | 41 | 5.5% |
| ecto | baseline | 992 | 222 | **22.4%** |

Notable patterns:
- **`mox`**: 3 false-positive `Survived → Killed` flips under
  persistent. `Mox.Server` module-replacement state survives reset
  hooks (application_env / ets / processes / persistent_term /
  on_exit) and contaminates subsequent mutants.
- **`ecto`**: 222-mutant drift dominated by `RuntimeError → Killed`
  (115) and `Survived → Killed` (~55). Persistent's warm BEAM masks
  errors that fresh-spawn surfaces, and produces false-positive
  kills via leaked Ecto.Query / planner cache state.
- **`nimble_options`**: residual 11 mutants classify as `:parse_error`
  (Bug 7 internal split) — `MismatchedDelimiterError` /
  `SyntaxError` from in-process recompile of patches that mix-spawn
  parses cleanly. Same source bytes, different parser outcome.
  Stryker JSON still surfaces them as `CompileError`; metrics
  block separates them as `parse errors:` distinct from
  `in-process compile errors:`.
- **`jason`**: 1.3% baseline drift is the cleanest persistent
  result. Body_literal mode +354 integer-literal mutants exposes
  new edges (5.5%).

### Wall-clock contribution of body-literal (mix mode, prior solo runs)

Solo measurements from the pre-49e3b64 session (the post-49e3b64
re-run had CPU contention from parallel benches):

| Target | Baseline ms | Body_literal ms | Δ ms | Contribution |
|---|---:|---:|---:|---:|
| nimble_options | 37,000 | 44,000 | 7,000 | 15.9% |
| mox | 26,000 | 35,000 | 9,000 | 25.7% |
| jason | 115,000 | 327,000 | 212,000 | **64.8%** |

`jason` is the largest body-literal target (354 new mutants) and
the wall-clock contribution of body-literal at 64.8% is well above
the Decision 2 ≥15% threshold.

`ecto` mix wall: 49 minutes baseline; persistent: 5.6 minutes
(8.7× speed-up — but at 22.4% drift cost, **NOT byte-identical**).

### Persistent worker post-fix metrics

`ac4df7c` introduced `:parse_error` category alongside the existing
`:unknown` mix-fallback reroute (`ee436e5`). Sample metrics block
from nimble_options persistent baseline post-49e3b64:

```
Persistent worker:
  ...
  crashes: 0  restarts: 0  filter-miss: 0
  in-process compile errors: 0  parse errors: 11  mix fallbacks: 16
```

The 16 mix fallbacks are mutants that classified as `:unknown`
(11) + `:parse_error` (5 some) and were successfully recovered via
mix-spawn. The 11 still-failing ones are `MismatchedDelimiterError`
materializations that the in-process recompile path produces but
mix-spawn doesn't — same patch bytes, different parser outcome.

### Decisions

**Decision 1 (body-literal default policy): KEEP OPT-IN**

Triggered by the spec's "Keep opt-in if mox/ecto shows persistent-
specific drift" branch. mox baseline drift 13.2%, ecto drift 22.4%
— both exceed V17 timeout-flap acceptance materially.

The kill-rate threshold (≥60% on deterministic targets) is met
(66.1%), and zero invalid body-literal mutants is achieved across
the n=419 sample. But the keep-opt-in trigger overrides those:
shipping body_literal default-on while the persistent worker
contaminates mox/ecto outcomes would compound user pain on those
project shapes.

v1.10 ships body_literal as `--enable body_literal`. Re-evaluate
default-on in v1.11+ once persistent-worker drift is closed.

**Decision 2 (body-literal routing): STAY FALLBACK**

Per spec, schema-routing migration triggers only when both
fallback-cost ≥15% AND Decision 1 = default-on hold. jason's
64.8% wall contribution clears the cost threshold, but Decision 1
= keep-opt-in voids the migration.

If Decision 1 is reconsidered in v1.11+, the schema-routing
migration becomes a real candidate. Forward scope filed in
PLAN.md v1.11 section.

### Default-flip-worker gate (forward-looking)

The "≥4 of 5 OSS targets clean" gate from PLAN.md v1.10 is **NOT
MET**:

| Target | Drift | Clean? |
|---|---:|---|
| nimble_options | 19% | NO (parse-class persistent recompile drift) |
| mox | 13% | NO (Mox.Server state pollution) |
| jason | 1-5% | borderline |
| ecto | 22% | NO (warm-state masking + false-positive kills) |
| gettext | n/a | NO (persistent worker boot crashes) |

v1.10 default `--worker-type` STAYS `mix`. Persistent remains
opt-in via `--worker-type persistent`. PERSISTENT_WORKER_GUIDE.md
documents the unsupported patterns surfaced by M25.

### M22 warning hint field-validation

First production fire of the v1.9 threshold on nimble_options
persistent baseline:

> Hint: persistent worker had high in-process fallback compile-error
> rate (20.0%). Consider --worker-type mix.

Threshold tuning unchanged for v1.10 — the hint correctly
identified a problematic run (14-mutant drift, 11 parse-class
errors).

### Pre-M25 historical note

The pre-M25 demo_app body_literal data (5/6 killed, +28% wall) is
preserved at `bench/results/demo_app.body_literal.terminal.txt`.
M25's 5-target matrix supersedes it for Decision 1 input but the
demo_app numbers remain a useful reference for the shape of body-
literal mutation impact on a small fixture.

## v1.8 final headline (c=4, both workers `--timeout 10000`)

| Target | mix wall | persistent wall | speedup |
|---|---:|---:|---:|
| demo_app | ~10 s | ~7-8 s | 1.3× |
| plug_crypto | **53 s** | **26 s** | **2.04×** |
| Decimal | **259 s** | **130 s** | **1.99×** |

Persistent is now strictly faster than mix on every benchmark
target. byte-identity preserved on all three targets — Decimal
mix and persistent produce identical Killed / Survived / Timeout
counts (363 / 91 / 0). plug_crypto retains a single mutant flap
within V17 acceptance (persistent kills, mix also kills now via
the same `--timeout 10000` knob).

**Versus the v1.7 mix baseline** (60 s ExUnit per-test default):

| Target | v1.7 mix | v1.8 persistent | absolute gain |
|---|---:|---:|---:|
| plug_crypto | 84 s | **26 s** | **3.23× faster** |
| Decimal | 660 s | **130 s** | **5.08× faster** |

Default still ships `--worker-type mix`. The default flip is a
v1.9+ decision — persistent is now strongly motivated by the
perf data but changes default user-visible behaviour and merits
a separate cycle.

The headline numbers above are the v1.8 final state. Sections
below trace how we got here (v1.7 baseline → M20 diagnostics →
M21 leak-vector fix → M21 phase 2 in-process fallback → M21
phase 3 timeout policy).

`bin/verify`'s `e2e_persistent` layer runs `mix mut.e2e
--worker-type persistent` against demo_app and asserts
byte-identity for the three fixture variants (default, coverage,
attribute) every CI run.

## v1.7 baseline: persistent slower than mix on real targets

This is the starting point for v1.8's perf-realisation work.

| Target | c=4 mix | c=4 persistent | byte-identical to mix? |
|---|---:|---:|---|
| demo_app | 8.9 s | 6.8 s | **yes** (21 killed / 10 survived in default; 23/10 in attribute) |
| plug_crypto | 84 s | 142 s | **yes** (38 Killed / 25 Survived / 1 Timeout — same stable-id sets) |
| Decimal | 11.0 min | 12.4 min | within V17 acceptance (11 timeout → killed flips on the existing timeout-class mutants; 1 RuntimeError → Killed) |

v1.7 shipped persistent worker as opt-in supported with byte-
identity proven on all three targets, but persistent was 1.7×
slower than mix on plug_crypto and 1.13× slower on Decimal at
c=4. demo_app is faster under persistent (1.3×) because its
per-mutant work is dominated by BEAM boot cost, but the leak-
vector reset overhead exceeded the saved boot cost on plug_crypto
and Decimal at v1.7. v1.8's M20 + M21 phases close this gap;
see sections below.

## v1.8 M20 Phase A: per-phase overhead breakdown

Phase A landed instrumentation inside the persistent worker so we
can answer "where does the time go" before optimising. Per-phase
microsecond timings are captured by
`Mut.Worker.PersistentRunner.Diag` and surfaced in the
`mutalisk.persistent` block of every Stryker JSON written under
`--worker-type persistent` (also rendered as a "Persistent worker:"
section in the terminal summary).

Diagnostics overhead measured on plug_crypto at c=4: 143 s with
diag on vs 147 s with `MUT_PERSISTENT_DIAG=0`. Within run-to-run
noise, well under the 5% bar.

Numbers below are from M20 Phase A bench runs at HEAD (commit
`fc31c7f` and follow-ups). Wall-clock columns are bench-script
totals; per-phase columns are medians across all persistent
workers (max where useful).

### plug_crypto

| | c=1 mix | c=1 persistent | c=4 mix | c=4 persistent |
|---|---:|---:|---:|---:|
| total wall | 128 s | 328 s | 84 s | 143 s |
| schema_workers wall | — | 152 s | — | 125 s |
| fallback_workers wall | — | 169 s | — | 7 s |
| boot per worker (median) | — | 421 ms | — | 392 ms |
| app startup per boot (median) | — | 4.2 ms | — | 4.0 ms |
| test load per boot (median) | — | 205 ms | — | 205 ms |
| ExUnit.run per mutant (median) | — | 605 ms | — | 604 ms |
| reset hooks (sum of medians) | — | <0.5 ms | — | <0.5 ms |
| filter lookup (median) | — | 0.1 ms | — | 0.1 ms |
| crashes / restarts | — | 1 / 1 | — | 1 / 1 |
| memory peak (per worker) | — | 61 MB | — | 62 MB |

**Dominant overhead at c=4**: the single timeout mutant in
plug_crypto's bench costs persistent 60 s of in-BEAM run +
60 s of mix-spawn retry (= 120 s on one worker). Mix only pays
the 60 s once. Because Task.async_stream waits for every
schema mutant before fallback starts, the other 3 workers
finish their share of normal mutants in ~5 s and then idle for
~115 s waiting on the timeout-blocked worker.

Reset hooks, filter lookup, app startup, and per-worker boot
are all sub-10 ms — none is the bottleneck on plug_crypto.

### Decimal

| | c=4 mix | c=4 persistent |
|---|---:|---:|
| total wall | 660 s | 744 s |
| schema_workers wall | — | ~610 s |
| fallback_workers wall | — | ~130 s |
| boot per worker (median) | — | ~920 ms |
| app startup per boot (median) | — | 3 ms |
| test load per boot (median) | — | 713 ms |
| ExUnit.run per mutant (median) | — | 36 ms |
| ExUnit.run per mutant (p95) | — | 215 ms |
| reset hooks (sum of medians) | — | <0.5 ms |
| filter lookup (median) | — | <0.1 ms |
| crashes / restarts | — | ~30 / ~30 |
| memory peak (per worker) | — | 69 MB |

**Dominant overhead at c=4**: ~30 mutants stall under persistent's
accumulated state and require a mix-spawn retry for byte-identity
(otherwise they flip Killed→Timeout — a correctness regression).
The persistent BEAM hits its 60 s deadline, mix-spawn re-runs the
mutant in a fresh BEAM and kills it. Each such mutant costs
~63 s. The schema_workers wall is dominated by these retries.

ExUnit.run itself is fast on Decimal (36 ms median, 215 ms p95) —
per-mutant work is not the bottleneck.

### demo_app

demo_app numbers come from `bin/verify`'s `e2e_persistent`
layer (`mix mut.e2e --worker-type persistent` at default
concurrency, c=4 in CI):

| | mix wall | persistent wall | speedup |
|---|---:|---:|---:|
| default fixture | ~10.1 s | ~7.9 s | 1.28× |
| attribute fixture | ~11.0 s | ~8.4 s | 1.31× |
| coverage fixture | ~14.9 s | ~12.2 s | 1.22× |

demo_app is small enough that BEAM-boot dominates per-mutant
work in mix; persistent amortises that and wins. byte-identity
checked: 21 killed / 10 survived in default and coverage,
23 killed / 10 survived in attribute (matches mix exactly).

### Dominant overhead summary

- **plug_crypto** (c=4): the lone timeout mutant costs persistent
  60 s in-BEAM + 60 s mix-spawn retry = 120 s on one worker, vs
  60 s in mix. The retry is correctness-required (see Phase B
  attempts below).
- **Decimal** (c=4): ~30 mutants stall in persistent due to
  accumulated state across mutants; each requires a 60 s
  mix-spawn retry to preserve byte-identity. Reset hooks
  (Application env / ETS / processes / persistent_term /
  OnExitHandler) don't catch this leak vector — diagnosis is
  M21-conditional.
- **demo_app**: no dominant overhead — already faster than mix.

App startup (median 4 ms) is NOT the bottleneck on any
target — F2's "scan and start every project app" is cheap in
practice, so the originally-hypothesised B.1 (scoped app
startup) is deferred unless Phase B Decimal data resurrects it.

## v1.8 M20 Phase B: optimisation attempts and results

Phase A showed the dominant per-mutant overhead in persistent
mode is **already very small** — boot is amortised, app
startup is ~4 ms, reset hooks are sub-millisecond, the
filter lookup is sub-millisecond, ExUnit.run wall is the
real per-mutant cost (median 36–600 ms across the three
targets). The persistent vs mix gap on plug_crypto and
Decimal is concentrated entirely in the **timeout/crash
recovery path**.

### Attempt B.1a — skip mix-spawn retry on persistent timeouts

Hypothesis: when persistent times out, the outcome IS
Timeout. Mix-spawn would just hit the same 60 s deadline.
Skipping the retry saves 60 s per timeout mutant on the
worker that hit it.

**Result on plug_crypto at c=4: 144 s → 93 s** (1.07× of
mix; was 1.71× slower in v1.7). byte-identical to mix.

**Result on Decimal at c=4: byte-identity regression.**
v1.7 had ~30 Decimal mutants where persistent stalled (state
leak across mutants) but the mix retry succeeded as Killed.
Skipping the retry flipped 31 Killed (in mix) to Timeout (in
persistent). Per the M20 prompt's "do not ship a Phase B
optimisation that breaks byte-identity" rule, **rolled back**.

### Attempt B.1b — shorter persistent deadline + mix retry

Hypothesis: if persistent times out faster (30 s instead of
60 s) the wasted-wait portion shrinks; mix retry still runs
at the full 60 s for byte-identity. State-leak timeouts
should resolve quickly in mix-spawn so the retry is cheap.

**Result on Decimal at c=4: 744 s → 988 s** (1.50× SLOWER).
The shorter deadline triggered ~9 *additional* timeouts on
mutants that legitimately complete in 30–60 s (not stuck,
just slow). Each extra false-timeout cost (30 s persistent +
60 s mix retry) − 35 s genuine ≈ 55 s wasted. Rolled back.

### Phase B summary

The persistent vs mix gap is dominated by timeout-class
mutants that need mix-retry for byte-identity (state leaks
that v1.7's `Mut.Worker.PersistentRunner.Reset` doesn't
catch). Closing the gap requires either:

1. **Plugging the state leak.** ~30 Decimal mutants stall
   under persistent's accumulated ExUnit/process state in a
   way the four reset vectors (Application env, ETS,
   processes, persistent_term, OnExitHandler) don't cover.
   This is a focused diagnosis task with the same shape as
   v1.7 F2 — instrument, find the leak vector, write a
   reset hook for it. Phase A diagnostics give the
   instrumentation; the diagnosis itself is M21-conditional
   work (gated on whether the leak is a single vector or
   many).

2. **Pipelining schema and fallback buckets.** When a
   persistent worker is blocked on a 60 s timeout mutant,
   the other 3 workers idle waiting for `run_schema_mutants`
   to drain before `run_fallback_mutants` starts. Letting
   idle workers pick up fallback work would absorb that
   wasted parallelism. Architectural change to
   `Mix.Tasks.Mut.run_with_concurrency`; deferred.

Per the M20 prompt's Phase B fallback acceptance, **M20
ships Phase A diagnostics and the timeout/crash code-clarity
split**, with this section documenting the residual
overhead and root cause. The 1.5× speedup bar is **not** met.

### Final bench numbers at v1.8 HEAD (c=4)

| Target | mix wall | persistent wall | speedup |
|---|---:|---:|---:|
| demo_app | ~10 s | ~7-8 s | 1.3× |
| plug_crypto | 84 s | 142 s | 0.59× (slower) |
| Decimal | 660 s | 744 s | 0.89× (slower) |

byte-identity preserved on every target between mix and
persistent (Decimal within V17 acceptance for the existing
timeout-class flap). `bin/verify`'s `e2e_persistent` layer
exercises this on demo_app every CI run.

## v1.8 M21 — Test-runtime parity bug fixed

**Root cause.** Phase A's hypothesis ("persistent has a state leak
that v1.7 reset hooks don't catch") was wrong. The actual cause was
a *test-runtime parity bug*: persistent ran tests under a different
ExUnit configuration than mix-spawn does. Two divergences:

1. **`max_failures: 1` was missing** in `PersistentRunner`'s
   `ExUnit.start/1`. The mix-spawn worker passes `mix test
   --max-failures 1`. Without it, persistent ran *every* selected
   test even after one failed — and ~30 Decimal mutants caused an
   early test to fail AND a later test to infinite-loop. Mix
   aborted at the first failure (1.5 s); persistent reached the
   loopy test and wedged the BEAM until the 60 s deadline.

2. **`wait_for_result` used an absolute deadline.** Mix-spawn's
   `Worker.collect/3` uses a *per-message* timeout — the deadline
   resets every time the worker BEAM produces output. Tests that
   take 60.5 s but emit per-test JSONL events while running survive
   in mix as long as the silence between messages stays under
   `timeout_ms`. Persistent's old absolute deadline killed those
   same tests at 60 s.

3. **`@timeout_ms` was 60 000 ms,** identical to ExUnit's per-test
   default. Race condition between "ExUnit notices and aborts" and
   "host fires deadline." Bumped to 70 000 ms — gives ExUnit's
   `:max_failures_reached` event time to land before the host gives
   up.

Fixed in `lib/mut/worker/persistent_runner.ex`,
`lib/mut/worker/persistent.ex`, and `lib/mix/tasks/mut.ex`.

### M21 results at c=4

| Target | mix wall | persistent v1.7 | persistent v1.8 (M20) | persistent v1.8 (M21) | persistent v1.8 (M21 + in-process fallback) | speedup vs mix |
|---|---:|---:|---:|---:|---:|---:|
| demo_app | ~10 s | ~7 s | ~7-8 s | ~7-8 s | ~7-8 s | 1.3× |
| plug_crypto | 84 s | 144 s | 142 s | 80 s | **77 s** | **1.09× (faster)** |
| Decimal | 660 s | 744 s | 744 s | 598 s | **623 s** | **1.06× (faster)** |

byte-identity preserved on every target — same Survived stable-id
sets vs mix worker, with V17-acceptance flap (mutants mix marked
Timeout that persistent kills via `max_failures: 1` aborting the
first failing test fast). On Decimal, persistent now produces 16
*more* Killed than mix (was 11 in v1.7 with mix-retry, persistent
gets there directly via the runtime parity fix). Zero Killed→Timeout
regressions.

### Why M21 didn't need a new reset hook

The four existing reset vectors (Application env / ETS / processes
/ persistent_term / OnExitHandler) ARE complete. The "leak" was
never about state accumulating across mutants — it was about
ExUnit running a different test schedule under persistent than
under mix-spawn. A single `max_failures: 1` config flip and a
per-message timeout closed both gaps.

## v1.8 M21 phase 2 — in-process fallback recompile

After the leak-vector half of M21 closed the byte-identity gap,
the in-process fallback half lands on top: instead of spawning a
fresh `mix test` for every fallback mutant, the persistent BEAM
recompiles the patched source in-process via `Code.compile_file/1`,
runs ExUnit, then restores the originals via `:code.purge/1` +
`:code.load_file/1` (the schema-build ebins on the runner's `-pa`
provide the originals).

New protocol line `RUN_FALLBACK <id> <compile_files>|<test_files>`.
Compile errors surface as `MUT_RESULT compile_error <us> <category>
<msg>` and become `Result{status: :invalid, recompile_category: cat}`
on the host — no mix-spawn retry, since mix would just fail with
the same compile error.

Fallback to mix-spawn on `:filter_miss` / `:timeout` / `:crashed`
(same recovery contract as schema mutants). Empirically this branch
is rare on real targets — Decimal at c=4 produced **0 compile
errors and 0 invalid mutants** across all 75 fallback mutants in
the in-process bench.

### Bench numbers at c=4 (M21 phase 2)

| | mix wall | persistent (M21 + in-process fallback) | speedup |
|---|---:|---:|---:|
| demo_app | ~10 s | ~7-8 s | 1.3× |
| plug_crypto | 84 s | 77 s | 1.09× |
| Decimal | 660 s | 623 s | 1.06× |

byte-identity preserved on every target; demo_app fixture's 4-6
fallback mutants per variant verified through `bin/verify`'s
`e2e_persistent` layer. Decimal: same V17-acceptance flap as M21
phase 1 (persistent kills 17 mutants mix marks Timeout); zero
unexpected Killed→Timeout regressions; zero Invalid; zero Errors.

## v1.8 M21 phase 3 — drop ExUnit per-test timeout to 10 s

**Diagnosis.** After M21 phase 2, Decimal at c=4 still had a
long-tail of 21 mutants in mix (4 in persistent) that consumed
the full 60 s ExUnit per-test default deadline before being
detected. 60 s is the wrong number for mutation-test workloads:
mutation-introduced bugs are CPU-bound infinite loops or
unbounded recursion, and 60 s of wall-clock is not what we need
to confidently classify them — 1-10 s is.

**Fix.** Both worker types now run ExUnit with `timeout: 10_000`:

- **Persistent runner** sets `timeout: 10_000` in `ExUnit.start/1`
  alongside the existing `max_failures: 1`.
- **Mix-spawn worker** passes `--timeout 10000` on its `mix test`
  command line for parity.

Tests legitimately needing more (e.g. integration / network
fixtures) can override per-test via `@tag timeout: 60_000`.
Mutation-testable codebases generally have unit-test scoped
runtimes well under 10 s; the byte-identity check vs the mix
worker surfaces any false positive.

### Bench numbers at c=4 (M21 phase 3, both workers `--timeout 10000`)

| Target | mix wall | persistent wall | speedup |
|---|---:|---:|---:|
| demo_app | ~10 s | ~7-8 s | 1.3× |
| plug_crypto | **53 s** | **26 s** | **2.04×** |
| Decimal | **259 s** | **130 s** | **1.99×** |

The 1.5× M20 acceptance bar is now **comfortably met on both
real targets**. Both workers got faster vs the v1.7 baseline
(plug_crypto 84 s → 53 s mix, 144 s → 26 s persistent;
Decimal 660 s → 259 s mix, 744 s → 130 s persistent).

byte-identity check post-M21-phase-3:

- demo_app, plug_crypto: unchanged from earlier phases.
- Decimal: **mix and persistent now produce identical Killed/
  Survived/Timeout counts** (363 / 91 / 0 — both report 0
  timeouts because the 10 s threshold catches all of them as
  Killed via `max_failures: 1` aborting on the first failed
  test). The "killed/timeout flap" V17 explicitly allowed is
  no longer needed at this timeout. Same 2-mutant
  mutator-generation difference at line 1874 as v1.7.

### Why 10 s

Per-test wall time on Decimal/plug_crypto/demo_app under no
mutation never exceeds a few hundred milliseconds. ExUnit's
60 s default is a reasonable safety net for application test
suites that exercise external systems; it's the wrong default
for *mutation-test* workloads where fast loop detection is
the actual goal. The persistent runner explicitly chooses the
mutation-test default; mix-spawn workers do the same on the
command line for fairness.

If a target has a legitimately long-running test (e.g. a slow
integration test brought into scope by static selection), the
ExUnit `@tag timeout: ms` machinery overrides per-test. v1.8.x
ships 10 000 ms; future versions can revisit per-target if a
case emerges.

### Headline summary across all v1.8 phases

| Target | v1.7 mix | v1.7 persistent | v1.8 final mix | v1.8 final persistent | speedup vs v1.7 mix |
|---|---:|---:|---:|---:|---:|
| demo_app | ~10 s | ~7 s | ~10 s | ~7-8 s | 1.3× |
| plug_crypto | 84 s | 144 s | 53 s | **26 s** | **3.23× faster** |
| Decimal | 660 s | 744 s | 259 s | **130 s** | **5.08× faster** |

### Diagnostics overhead

Measured on plug_crypto at c=4: 143 s with diagnostics on
vs 147 s with `MUT_PERSISTENT_DIAG=0`. Within run-to-run
noise, well under the 5% bar required by M20 acceptance.

## v1.6 default change

`mix mut` now defaults to parallel execution at `--concurrency = min(System.schedulers_online(), 4)`. Use `--concurrency 1` for v1.5 sequential behaviour. Smoke runs in this benchmark file annotated with `c=N` are at concurrency `N`; runs without an annotation use the v1.5 sequential default unless explicitly noted.

## Concurrency speedup curve (M17)

Reference machine: macOS, OTP 28 (erts-16.2), Elixir 1.19.5, 12 schedulers online.

### Wall-clock by target × concurrency

| Target | c=1 | c=2 | c=4 | c=8 |
|---|---:|---:|---:|---:|
| demo_app | 47 s | 39 s | 24 s | 21 s |
| plug_crypto | 128 s | 95 s | 84 s | 79 s |
| Decimal | 40.8 min¹ | 20.6 min | 11.0 min² | 7.4 min |

¹ Decimal c=1 wall taken from BEAM-internal monotonic Phases total (`Mutalisk run complete in Xms`); the system was suspended mid-run, which corrupted `bench.wall_ms` (5062 s) but not the monotonic phase timer used for internal totals.

² Decimal c=4 wall from PROMPT_16's run on the same hardware (commit `1ea6ed0`).

### Speedup vs c=1

| Target | c=2 | c=4 | c=8 |
|---|---:|---:|---:|
| demo_app | 1.21× | 1.96× | 2.24× |
| plug_crypto | 1.35× | 1.52× | 1.62× |
| Decimal | 1.99× | 3.73× | 5.55× |

The curve flattens between c=4 and c=8 on the small targets (demo_app per-mutant wall ≈ 1 s, parallel overhead dominates) and on plug_crypto (per-mutant ≈ 2 s, modest gains past c=4). Decimal scales nearly linearly to c=4 (0.93 × ideal) and gives a meaningful but sub-linear gain to c=8 (0.69 × ideal). Cap-at-4 default rationale: best speedup-per-extra-BEAM-memory trade-off across the three targets, with `--concurrency 8` available for compute-heavy projects on machines with the cores.

### Outcomes byte-identity (M17 acceptance gate)

The byte-identity check is on the **stable_id sets per terminal status**, not on the entire JSON (durations vary). The result-class that reflects mutator/test correctness is `Survived`: a mutant survived iff every selected test passed. `Killed`/`Timeout` flap is acceptable timing variance for slow mutants whose worker BEAM finishes near the 60 s per-mutant timeout — under parallel I/O contention some flip from Killed to Timeout (and vice versa).

| Target × pair | Killed-set identical | Survived-set identical | Timeout drift |
|---|:---:|:---:|---:|
| demo_app c=1 vs c=2/4/8 | yes | yes | 0 |
| plug_crypto c=1 vs c=2/4/8 | yes | yes | 0 |
| Decimal c=1 vs c=2 | flapped (4) | **yes (92)** | 0 |
| Decimal c=1 vs c=4 | flapped (8) | **yes (92)** | +3 |
| Decimal c=1 vs c=8 | flapped (8) | **yes (92)** | -3 |

`Survived` sets across all four Decimal concurrency levels are the same 92 stable_ids — every mutant the test suite cannot detect at c=1 stays undetected at c=2/4/8 and vice versa. No `Survived` mutant flipped to `Killed` or back. The 4–8 mutant flap between Killed↔Timeout is concentrated on a small set of stable_ids that hover near the 60 s timeout cap; this is documented timing variance, not a parallelism correctness defect.

### Decimal at the new default (c=4): full snapshot

```
Schema:    304/381 killed (79.8%)   wall: 11.0 min
Fallback:  43/75 killed (57.3%)
  guard_comparison_boundary:    5/20 killed
  guard_comparison_negation:    20/24 killed
  guard_type_test:              18/31 killed
Skipped:   1133  (unsupported_dispatch: 1050, missing_oracle_site: 76, ...)
Invalid:   0
Errors:    0
Timeouts:  21
```

Decimal is comfortably under the v1.5 30-minute budget at the new default, and the fallback bucket produces real signal (post-Phase-B). The OOM_DECIMAL acceptance bar is met under v1.6's default.



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

### Acceptance evaluation (revised after Phase B + Phase C parallel)

The post-OOM_DECIMAL Phase B/C mission landed two further fixes that change the picture:

| Run | Wall | Schema score | Fallback score | Invalid | Errors | Timeouts |
|---|---:|---:|---:|---:|---:|---:|
| Decimal static c=1 (pre-Phase B) | 33.5 min | 80.3 % | 0/75 (75 invalid) | 75 | 0 | 11 |
| Decimal static c=4 (post-Phase B + Phase C.1) | **11.0 min** | 78.5 % | **43/75 (57.3 %)** | **0** | 1 | 21 |

**Phase B (Mix lock-check bypass in `Mut.Recompile`)**: 74/75 fallback invalids on Decimal were Mix preflight rejections (`lock mismatch`); 1/75 was an `import Decimal.Macros` resolution failure. The fix replaces the `mix mut.recompile` shellout with `elixir --eval` directly, bypassing Mix entirely. Sandbox.reset was tightened in the same commit so dep ebins survive (the old mix-based recompile was inadvertently restoring them on each iteration).

**Phase C.1 (`--concurrency` parallel workers)**: schema_workers went 3.79× at c=4 on Decimal, total wall 3.06×. plug_crypto static went 1.52× on the same flag.

- ✓ Decimal completes within 30-minute budget (11.0 min at c=4).
- ☐ Coverage selection reduces fanout ≥10× (still 1.5×; coverage is orthogonal to parallelism — same 6 test files).
- ☐ Coverage reduces fanout ≥10×. Observed fanout reduction: 2.0 → 1.3 tests/mutant ≈ 1.5× on Decimal. The suite is small (only 6 test files in the bench branch with property tests disabled), so static selection already touches few files; coverage gains are correspondingly capped.
- ✓ Next bottleneck documented (per-mutant `mix test` cold-start; persistent BEAM is the v1.7 lever — see `V16_PERFORMANCE.md`).
- ✓ plug_crypto outcomes unchanged in static mode (c=1 and c=4 byte-identical).
- ✓ plug_crypto outcomes match within ±0 mutants in coverage mode.
- ✓ BEAM memory bounded under load; peak 82 MB on Decimal vs. 120 GB pre-fix.
- ✓ Decimal fallback bucket produces real signal (43/75 killed, 0 invalid).

v1.5 acceptance: **met** under `--concurrency 4`. The 30-min wall budget and the "fallback produces signal" bar are both cleared. The 10× fanout target is unchanged (1.5× on Decimal due to its 6-file test suite); pursuing it further requires either richer test discovery or moving cost-per-mutant down via persistent BEAM (v1.7). The blocking failure (host OOM and inability to reach mutation execution on Decimal) is resolved. Time and fanout targets are not yet met, but the runtime now produces signal that scopes v1.6 work concretely:

1. **Parallel workers** is the obvious lever — schema_workers wall ≈ 33 minutes is the entire budget. Even 4-way parallelism brings Decimal under 10 minutes.
2. **Decimal's fallback bucket compiles to 75/75 invalid** under both selection modes. This is independent of OOM but surfaced now that Decimal executes. Fallback engine on Decimal hits `CompileError` for every guard mutation; needs a separate diagnostic pass before fallback adds signal on this target.
3. **Decimal-class targets exercise an app-name surface mutalisk had not handled.** Any future target that shares an app name with one of mutalisk's transitive deps' `optional_applications` would have hit the same hang. The fix (jason `runtime: false`) is general — but the wider class is worth keeping in mind: never let mutalisk transitively contribute to the target's runtime app graph.

## Persistent Worker Status (M19 Follow-up)

The persistent worker is now opt-in supported. The
`MUTALISK_PERSISTENT_EXPERIMENTAL=1` env gate was removed in
Mission F3 after the F1 (filter-miss) and F2 (project-app-startup)
fixes closed all three byte-identity gates: demo_app, plug_crypto,
and Decimal (the latter within V17 acceptance for the existing
timeout-class flap). See the v1.7 experimental section at the top
of this file for the side-by-side comparison table.

Do not treat persistent benchmark claims as accepted until these rows are filled by a later validation pass:

| Target | Worker | Concurrency | Outcome identity | Wall | Status |
|---|---|---:|---|---:|---|
| demo_app | mix vs persistent | 1 | previously byte-identical; needs rerun after baseline fix | TBD | pending |
| demo_app | mix vs persistent | 4 | previously byte-identical; needs rerun after baseline fix | TBD | pending |
| plug_crypto | mix vs persistent | 4 | failed before baseline fix | TBD | pending rerun |
| Decimal | mix vs persistent | 4 | not yet measured | TBD | pending |

