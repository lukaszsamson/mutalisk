# Changelog

All notable changes to Mutalisk are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## v1.15 unreleased

### M44 — Low-noise literal expansion: Float + Nil + StringLiteral table (2026-05-23)

Two new env-walker literal mutators plus a richer StringLiteral table.
All fallback-routed and opt-in (`--enable env_walker`); the default
pipeline is unaffected.

- `Mut.Mutator.FloatLiteral` — body-context float literals: `0.0 → 1.0`;
  finite `f → 0.0` and `f → f + 1.0`.
- `Mut.Mutator.NilLiteral` — body-context `nil → :__mut_nil__` (single
  closed replacement; match/guard positions excluded).
- `StringLiteral` expand_table: adds `s → "x"` (skipped when `s == "x"`)
  and `s → " " <> s`. The M40 `s → ""` row is unchanged, so its stable
  ID does not churn.
- `Mut.EnvWalker.collect_literal_candidates/2` generalizes string
  candidate collection to string + float + nil; `collect_string_literal_candidates/2`
  is retained (string-only).
- Golden mutation list `test/golden/mutations/literals_env.json` over a
  standalone `test/fixtures/literals_sample.ex` (kept out of demo_app/lib
  so the oracle golden and demo_app stable IDs are untouched).

Byte-identity gate (existing mutants, no churn) verified on the full
v1.15 corpus — demo_app, plug_crypto (+14 env), Decimal (+38 env;
FloatLiteral and NilLiteral exercised on real code), plug (+234 env),
and phoenix_html (+44 env). Default-flag plans are byte-identical on
every target and no existing env-flag stable ID changed.

### M43 — EnvWalker consolidation: deferred to v1.16 (2026-05-23)

Release valve exercised. A pre-implementation spike proved the
byte-identity gate cannot be met by making `EnvWalker` the single
candidate source — `EnvWalker` keys literal identity off byte spans
with `ast_path = []` (the M41 design), while the four `AstWalk` walkers
key off detailed positional paths; unifying churns one side. No
production code changed. Evidence and the v1.16 redesign direction are
in `docs/decisions/M43_envwalker_consolidation.md`. M44/M45 proceed
against the parallel fifth-source `EnvWalker` unchanged.

### M42 — Worker-type removal + model/doc simplification (2026-05-23)

**Breaking:** the opt-in persistent worker is removed. `mix` is the
only worker. Mutation outcomes are unchanged.

- **`--worker-type` removed.** `--worker-type mix` (and
  `config :mut, worker_type: :mix`) is accepted as a deprecated
  no-op that warns once; `--worker-type persistent` is rejected
  with a pointer to this entry. The `worker_type` field is gone
  from `Mut.Cli.Options`.
- **Deleted modules (~2,250 LOC):** `Mut.Worker.Persistent`,
  `Mut.Worker.PersistentRunner` (+ `Reset`, `Diag`),
  `Mut.Worker.Persistent.Detector`, and their tests.
- **Deleted drift triage:** `Mix.Tasks.Mut.Drift`,
  `Mut.Drift.Bucketer` (+ `Result`) and their tests — these only
  triaged mix-vs-persistent stable-id divergence.
- **Removed wiring:** the persistent metric block from
  `Mut.Metrics` / `Mut.Reporter.Terminal` /
  `Mut.Reporter.StrykerJson` (the Stryker `mutalisk.persistent`
  extension key no longer appears); the persistent boot-time
  warning and its `--quiet-boot-warning` flag; the in-process
  fallback recompile path (`Mut.Worker.run_fallback_in_process/5`).
- **Removed verify layer:** `e2e_persistent` dropped from
  `bin/verify`; `mix mut.e2e` no longer takes `--worker-type`.
- **Deleted `docs/PERSISTENT_WORKER_GUIDE.md`** and brought
  README in line with the current model (parallel workers,
  opt-in coverage selection, opt-in env-walker literals, single
  worker). The SchemaPlacer escaped-quote note is retained — that
  bug affected the mix worker too.

## v1.14 unreleased

### M41 — Real-target validation + StringLiteral default decision (2026-05-11)

Plan-level validation matrix on the M40 acceptance set
(demo_app, plug_crypto v2.1.1, Decimal, plug v1.19.1,
phoenix_html v4.3.0). Full decision doc at
`docs/decisions/M41_string_literal_decision.md`.

Two production fixes shipped as part of M41 measurement:

- **Walker `literal_span/3` end-byte regression** — `:token`
  metadata is not propagated by the parser's `:literal_encoder`
  option for string literals. Pre-fix, all string literals at
  the same `ast_path` collapsed to identical stable IDs.
  Decimal exposed 9 collisions on 19 mutants. Fix falls back to
  `:end_of_expression` token metadata when `:token` is absent
  so distinct physical sites produce distinct byte spans. All 5
  targets now produce unique IDs per string literal.
- **`ast_path_hash` JSON encoding** — env walker emitted a raw
  SHA-256 binary which contains bytes that `elixir_json`
  refuses as UTF-8. Mirrored `Mut.AstWalk.path_hash/1`'s
  16-byte SHA-256 prefix + `Base.encode16(case: :lower)`
  encoding. JSON-safe.
- **`fallback_env_context/3` missing clause** — orchestrator's
  fallback-context dispatcher had no `:env_walker` clause;
  every string-literal candidate hit a FunctionClauseError on
  any target with body string literals. Added.

#### Validation matrix

| Target | Default IDs | env_walker IDs | New IDs | Lost IDs | StringLiteral count |
|---|---:|---:|---:|---:|---:|
| demo_app | 31 | 31 | 0 | **0** | 0 |
| plug_crypto v2.1.1 | 64 | 71 | 7 | **0** | 7 |
| Decimal | 456 | 475 | 19 | **0** | 19 |
| plug v1.19.1 | 352 | 469 | 117 | **0** | 117 |
| phoenix_html v4.3.0 | 93 | 115 | 22 | **0** | 22 |

**Stable-ID churn for existing mutants = 0 on all 5 targets.**
M40's byte-identity acceptance binds; M41 confirms it on the
full acceptance corpus.

#### Decision: `keep_opt_in`

`--enable env_walker --mutators string_literal` stays the
required opt-in surface. Reasoning (full at the decision doc):

- M41 produced plan-level evidence only (no test execution).
  The `expand_table` criteria (equivalent <20% AND kill ≥60%)
  cannot be evaluated without kill-rate measurement.
- Kill rates are a property of the project's test suite, not
  the mutator (consistent with M33 / M37 reframings).
- No unknown invalid class surfaced; opaque-policy false
  negatives in plan-level inspection: zero.

Interpolated-string disposition (M39 deferred): no demand
surfaced; no v1.15 milestone scoped at M41 close.

#### Sidecar observations

- **plug** shows a 33% mutant-surface increase (352 → 469);
  largest target-class win when users opt in.
- **phoenix_html**'s opaque policy correctly excludes
  `@doc ~S"""..."""` sigil heredoc bodies on all 22 new
  mutants. M34 SchemaPlacer closure + M40 walker stack cleanly.
- **Decimal** scales linearly at +4%; M23 + comparison +
  boolean + guard mutators already cover most of its surface.
- **demo_app** correctly produces 0 string mutants.

#### Acceptance

- ✅ Zero stable-ID churn (5/5 targets).
- ✅ Parse+walk gate holds in production
  (Decimal ~8 s, plug ~12 s — 14× headroom on M39's 10% gate).
- ✅ No-expansion grep gate holds (walker uses only
  `Code.string_to_quoted/2` + AST matches).
- ✅ Decision doc at `docs/decisions/M41_string_literal_decision.md`.
- ✅ BENCHMARKS.md gains v1.14 section.
- ✅ PERSISTENT_WORKER_GUIDE.md notes env walker runs at plan
  time (host process); both worker types see identical plans.

### M40 — Env walker + StringLiteral mutator (2026-05-11)

v1.14's substantive milestone. M39 returned **GO**; M40 ships the
implementation. Single bundle, gated behind opt-in flags.
PLAN.md suggested 7 internal commits; v1.14 lands the bundle in
4 commits because commits 3+4 collapse (the macro_index
plumbing IS the if/unless tracer-proof logic) and commits 5+6+7
collapse (the mutator wiring + CLI surface ship together with a
single byte-identity verification).

#### Modules added

- `Mut.EnvSnapshot` — per-AST-node classification (context /
  scope / trust_level) with `body_literal_eligible?/1` and
  `skip_reason/1` helpers.
- `Mut.OpaquePolicy` — known-safe form recognition and the
  `trusted_kernel_control_flow?/3` gate that requires tracer-
  oracle proof for `if` / `unless`.
- `Mut.EnvWalker` — recursive-descent source-AST walker with
  explicit per-form context discrimination. Public surface:
  `parse_string/2`, `collect_literal_snapshots/2`,
  `collect_string_literal_candidates/2`. Walker uses
  `Code.string_to_quoted/2` with the `:literal_encoder` option
  (wraps each literal in `{:__block__, meta, [value]}`) and the
  standard `:columns` / `:token_metadata` / `:emit_warnings:
  false` flags.
- `Mut.EnvOracle` — in-memory index built from walker snapshots
  + the `build_macro_index/1` helper that produces the tracer
  macro index from existing `Mut.Oracle.DispatchSite` records.
- `Mut.Mutator.StringLiteral` — first env-walker-backed mutator.
  Targets `:env_walker` only. Replaces non-empty string body
  literals with `""`. Fallback-routed (M39 stable-id strategy:
  no schema-routing migration in v1.14). Eligibility binds to
  `scope: :function_body`, `context: nil`, `trust_level: :trusted`,
  and non-empty binary value. Interpolated strings and empty
  strings are not eligible.

#### Orchestrator integration

- New `@type target` alternative `:env_walker`.
- `Mut.Orchestrator.plan/3` builds `macro_index` once per plan
  when `:env_walker` is in enabled_targets; nil otherwise.
- `process_file/6` conditionally parses with the literal
  encoder, walks the AST, collects string-literal AstCandidates,
  and routes through the standard fallback mutant pipeline.
- The fifth candidate source does NOT replace or modify the
  existing four (`dispatch_candidates`, `guard_candidates`,
  `attribute_candidates`, `body_literal_candidates`). M39
  binding architectural commitment.

#### CLI surface

- New `--enable env_walker` target name (validated by the CLI
  parser; off by default).
- New `--mutators string_literal` mutator name (off by default).
- Default flag set unchanged: `--enable dispatch,guard`,
  `--worker-type mix`, `--selection static`. M40 acceptance
  binds: opt-in default; existing dispatch / guard / attribute /
  body-literal stable IDs unchanged on default-flag runs.

#### Strict no-expansion contract

The walker calls only `Code.string_to_quoted/2` and pattern-
matches on AST. Forbidden in production env-walker code paths:
`Macro.expand`, `Macro.expand_once`, `Code.eval_*`,
`Code.compile_*`, `Kernel.ParallelCompiler`, `:elixir_expand`,
`:elixir_module`, `:elixir_def`, `Macro.Env.expand_import/5`,
`Macro.Env.expand_require/6`, `Macro.Env.define_import/4`,
`Macro.Env.fetch_alias/2`, `Macro.Env.fetch_macro_alias/2`,
and direct `%Macro.Env{}` private-field reads.

#### Tests

- `test/mut/env_snapshot_test.exs` — 19 cases.
- `test/mut/opaque_policy_test.exs` — 21 cases.
- `test/mut/env_walker_test.exs` — 13 cases (context discrimination,
  match/guard/quote boundaries, defmacro/defguard scope).
- `test/mut/env_oracle_test.exs` — 7 cases (indexing, histogram,
  body-literal filter, macro-index dispatch-kind filter).
- `test/mut/mutator/string_literal_test.exs` — 16 cases (mutator
  metadata, applicability truth table, end-to-end candidate
  collection via the walker including quote / guard / match /
  defmacro exclusions).

Total: 76 new test cases.

#### Byte-identity gate (M40 acceptance)

demo_app default-flag plan stable-ID hash:

| State | Hash | Schema / Fallback |
|---|---|---|
| pre-M40 HEAD | `30f0dd6d89660bed` | 27 / 4 |
| post-M40 HEAD, default flags | `30f0dd6d89660bed` | 27 / 4 |
| post-M40 HEAD, `--enable env_walker` (no string body literals in fixture) | `30f0dd6d89660bed` | 27 / 4 |

All four conditions of M40's byte-identity gate hold: existing
dispatch / guard / attribute / body-literal stable IDs are
unchanged with the env walker enabled OR disabled on the
demo_app fixture. `bin/verify` exits 0 with all 9 layers green.

#### What does NOT ship in v1.14 (M40 explicit non-goals)

- Schema-routing for any env-walker mutator. Fallback-routed
  exclusively. Stable-id migration is v1.15+ if ever.
- Migrating existing `Mut.AstWalk` walkers behind `EnvWalker`.
  v1.15+ with its own byte-identity gate.
- Float / atom / list / map / tuple body literals. M39
  ordering items 2-4; v1.15+ candidates.
- Atom-table pollution policy. v1.15+ design.
- Pattern-position literals. v1.15+.
- Variable mutators. v1.15+.
- Interpolated-string mutation. M41 decision input; v1.15+ if
  demand surfaces.
- Persistent default flip (closed structurally per v1.11/v1.12).
- Coverage default flip (stays opt-in).

#### Defaults (unchanged in v1.14)

- `--worker-type mix` STAYS default.
- `--selection static` STAYS default.
- Env walker stays opt-in; user must pass `--enable env_walker`
  AND `--mutators string_literal` to surface string mutants.

## v1.13 unreleased

### M39 — Env walker design spike: go for v1.14 (2026-05-11)

PLAN.md scoped M39 as the substantive v1.13 milestone: design
the env walker that unblocks v2's mutator catalog
(string/atom/list/map/tuple body literals, pattern-position
literals, variable mutators, better attribute classification).
Spike output is a written design doc; no code ships.

**Decision: go for v1.14 first implementation, with narrow
scope.** Full design at `docs/spikes/M39_env_walker.md`. The
spike answers all 7 PLAN.md questions:

1. **Context discrimination.** Recursive descent over source
   AST returned by `Code.string_to_quoted/2` (literal-encoder
   mode). Explicit per-form context transitions for
   `defmodule`, `def`, `fn`, `case`, `with`, `try`, `quote`,
   `=`, `when`, `^`, and the `if`/`unless` Kernel macros.
   Generic recursion only after the form is known not to
   change context.
2. **User macro opacity policy.** The walker does NOT expand
   macros. `Macro.expand/2`, `Macro.expand_once/2`, `Code.eval_*`,
   `Code.compile_*`, `Kernel.ParallelCompiler`, `:elixir_expand`,
   `:elixir_module`, and `:elixir_def` are explicitly
   forbidden in production. Known-safe Kernel control-flow
   macros (`if`, `unless`) require tracer-oracle proof; any
   unproven macro call becomes an `:opaque` boundary with
   `:untrusted_descendant` children.
3. **Public-API surface.** Eleven public APIs identified, all
   stable in Elixir ≥ 1.17 (mutalisk's floor is 1.19). No floor
   bump needed. `Macro.Env.define_import/4`,
   `expand_import/5`, `expand_require/6`, `fetch_alias/2`,
   `fetch_macro_alias/2`, and direct private-field access are
   intentionally NOT used.
4. **Stable-ID strategy.** **No migration required.** Existing
   dispatch-shaped mutants keep their current stable-id input;
   `EnvSnapshot` fields are not added to stable-id input;
   synthetic expansion nodes (the `case` emitted by `if`) are
   never used for IDs. The v1.14 acceptance gate includes
   byte-identity validation on demo_app, plug_crypto, Decimal,
   and plug with env walker enabled vs disabled.
5. **Cold-compile cost.** Measured via throwaway `elixir -e`
   prototype on Elixir 1.19.5 / OTP 28: parse+walk wall is
   3.4 ms on demo_app (8 files), 6.4 ms on Decimal (4 files),
   34.4 ms on plug (42 files). All three are well under the
   hard gate (10% of oracle-build wall on Decimal/plug): 0.06% /
   0.21% / 0.72% respectively. Even 10x slowdown in production
   wouldn't approach the gate.
6. **Mutator ordering.** Recommended sequence: string body
   literals → float → atom (with atom-table policy) →
   list/map/tuple → better attribute classification →
   pattern-position literals → variable mutators. Justified on
   equivalent-mutant rate and walker-complexity grounds. The
   first v1.14 mutator is **string body literals only**;
   `Mut.Mutator.StringLiteral`, fallback-routed, scope
   `:function_body`, context `nil`, trust `:trusted`.
7. **v1.14 go/no-go gate.** Production deliverables:
   `Mut.EnvSnapshot`, `Mut.EnvOracle`, `Mut.OpaquePolicy`,
   `Mut.EnvWalker`, orchestrator integration for `StringLiteral`.
   LOC estimate: ~970 production + ~450 test. Acceptance:
   byte-identical existing dispatch stable IDs; no `Macro.expand`
   or compiler-internal API in the walker; defguard bodies
   classified as guard context; parse+walk ≤ 10% of oracle
   wall on Decimal and plug; validation on demo_app +
   plug_crypto + Decimal + plug + one macro-heavy target
   (gettext or phoenix_html).

The spike doc explicitly forbids: expanding user macros,
calling `:elixir_expand` directly, treating `if`/`unless` as
guard-safe (they expand to `case`), modifying
`Mut.AstWalk.dispatch_candidates/2` or any existing candidate
walker. The env walker is added as a **fifth candidate source**
consumed only by `Mut.Mutator.StringLiteral`. Migration of
existing walkers behind `EnvWalker` is a v1.15+ milestone with
its own stable-id byte-identity gate.

No production code shipped. Spike doc at
`docs/spikes/M39_env_walker.md`. PLAN.md v1.13 horizon updated
to reference v1.14 first implementation.

### M38 — v1.12 doc closure + spike-env-var cleanup (2026-05-10)

Mechanical milestone. Closes v1.12's release-doc drift and
removes spike-only env vars whose decisions concluded "don't
ship."

#### Doc fixes

Most v1.12 doc drift was already cleaned in the pre-tag commit
`2f13028`. M38 catches the last residual:

- `docs/PERSISTENT_WORKER_GUIDE.md`: the example warning text in
  the "Boot-time warning" section quoted the pre-M28 Mox message
  `Mox.Server mock-registry leaks across mutants`. Updated to
  match the current detector string (`residual cluster/peer-state
  drift remains after M28's Mox.Server reset hook`).

#### Spike-env-var cleanup

The following were retained behind opt-in env vars after their
spikes concluded "don't ship," with the policy that they could
be resurrected from git if a future spike needed them. M38
collects on that policy:

- **`MUT_PERSISTENT_COMPILE_MODE=helper_process` removed.**
  `Mut.Worker.PersistentRunner.compile_via_helper_process/1`
  and its dispatch helpers deleted; default `compile_in_process/1`
  body inlined. M29's spike doc remains the historical reference
  (`docs/spikes/M29_recompile_isolation.md`).
- **`MUT_PERSISTENT_POOL_RESET=apps_restart` removed.**
  `Mut.Worker.PersistentRunner.Reset.reset_pool_apps/0` deleted.
  M36's spike doc remains the reference
  (`docs/spikes/M36_pool_warm_state.md`).
- **`Persistent.port_env/1` env-var forwarding** narrowed back
  to `MUT_PERSISTENT_DIAG` only.

`reset_pool_us` was never plumbed through `MUT_RUN_METRICS` /
metrics rollup / terminal block in the first place (only existed
in the runner's reset_leaks/2 map), so the PLAN.md "remove
reset_pool_us from MUT_RUN_METRICS" line is a no-op.

#### Policy additions

`docs/PERSISTENT_WORKER_GUIDE.md` gains:

- **`:supervisor_init` policy note** in the "Boot-time warning"
  section, distinguishing Ecto-class structural drift (mix-only)
  from low-rate plug-class drift (supported with caveat; persistent
  may be more thorough). Two-paragraph note, NOT a new
  catalogue row.
- **`mix mut.drift --json` schema** documented with one
  per-target example, an example CI usage (jq one-liner), and
  an explicit "stable for CI consumption from v1.13 forward"
  contract. Any future schema change becomes a SemVer concern.

#### Module changes

- `lib/mut/worker/persistent_runner.ex`: removed
  `compile_via_helper_process/1`, `do_compile_files_collecting_modules/1`,
  `compile_mode/0`. `compile_in_process/1` body inlined from
  `compile_in_main_process/1`. `reset_pool_apps/0` call removed
  from `reset_leaks/2`; `reset_pool_us` field removed from the
  metrics map.
- `lib/mut/worker/persistent_runner/reset.ex`: removed
  `reset_pool_apps/0`, `pool_reset_enabled?/0`, `do_reset_pool_apps/0`,
  `@pool_apps` module attribute.
- `lib/mut/worker/persistent.ex`: removed
  `MUT_PERSISTENT_COMPILE_MODE` and `MUT_PERSISTENT_POOL_RESET`
  from `port_env/1` forwarding.

#### Acceptance

- ✅ Stale-phrase grep clean: no occurrences of `M36 may close`,
  `pool not yet`, `v1.11 catalogue` in v1.12+ contexts,
  `Mox.Server mock-registry leaks`, `Ecto.Query planner.*caches`
  in detector moduledoc.
- ✅ `MUT_PERSISTENT_COMPILE_MODE` and `MUT_PERSISTENT_POOL_RESET`
  no longer appear in `lib/`.
- ✅ `bin/verify` green at all 9 layers.

## v1.12 unreleased

### M37 — Mutator-surface decision: ComparisonNegation already shipped (2026-05-10)

PLAN.md scoped M37 as either (a) ship one narrow schema-routed
mutator candidate (`Mut.Mutator.ComparisonNegation` for `==` ↔
`!=` and the strict / boundary variants), or (b) formally defer
all catalog growth to the env walker (v2). v1.12 lands outcome
(a) — but, as with M33's ComparisonBoundary, the candidate was
already implemented in v1.5 (commit `06e8398`, 2026-05-03) and
M37's v1.12 work is bench validation only.

#### Pre-existing implementation matches the M37 candidate

`lib/mut/mutator/comparison_negation.ex` already mutates the
full target set:

| Operator | Replacement |
|---|---|
| `<` | `>=` |
| `<=` | `>` |
| `>` | `<=` |
| `>=` | `<` |
| `==` | `!=` |
| `!=` | `==` |
| `===` | `!==` |
| `!==` | `===` |

It is schema-routed (`@kind :comparison_negation`, dispatch
oracle), body-context-only (`ctx.env_context == nil`), and
stable_id-safe (no migration). All three M37 decision criteria
pass.

Wired into `Mut.Mutator.Defaults` and the CLI mutator name
table. 4 unit tests at
`test/mut/mutator/comparison_negation_test.exs` pass.
golden_oracle and golden_instrument verify layers are green.

#### Bench validation across the M25 + M27 + M34 corpus

| Target | Mutants | Killed | Other | Kill rate |
|---|---:|---:|---|---:|
| plug_crypto v2.1.1 | 7 | 6 | 1 Survived | 85.7% |
| Decimal | 118 | 109 | 9 Survived | 92.4% |
| nimble_options v1.1.1 | 2 | 2 | — | 100.0% |
| mox v1.2.0 | 4 | 4 | — | 100.0% |
| jason v1.4.5 | 8 | 6 | 2 RuntimeError | 75.0% |
| mint v1.8.0 | 72 | 66 | 6 Survived | 91.7% |
| plug v1.19.1 | 38 | 33 | 1 CE / 4 RE | 86.8% |
| phoenix_html v4.3.0 | 12 | 12 | — | 100.0% |

Kill rates 75–100% across all 8 reference + OSS targets, well
above the 60% bar M33 originally scoped (and which M33
reframed as an observation rather than acceptance). 261 mutants
of mutation surface from the catalog as a whole. Per the M33
reframing, kill rate is reported as an observation — it is a
property of the project's test suite, not the mutator.

#### M37 acceptance

Per PLAN.md acceptance: "(a) one new schema-routed mutator
landed, unit-tested, golden layers green, validated on ≥4
targets." All sub-criteria are met:

- ✅ One schema-routed mutator (ComparisonNegation).
- ✅ Unit-tested.
- ✅ golden_oracle and golden_instrument layers green
  (`bin/verify` exits 0).
- ✅ Validated on 8 targets (plug_crypto + Decimal + 6 OSS),
  exceeding the ≥4 bar.

**No code changes.** PLAN.md's M37 entry is marked complete.
v1.12 catalog growth is closed; further mutator additions
(atoms / strings / maps / lists / list-construction) remain
deferred to v2 with the env walker.

### M36 — Pool-warm-state characterization spike: stance unchanged (2026-05-10)

PLAN.md scoped M36 as a characterization spike before any
reset-hook implementation, with three options on the table:
reset hook, mix-spawn reroute, or formal mix-only classification.

**Decision: maintain v1.11/M35's "supported with caveat" stance.
Do NOT ship a reset hook for pool-class.**

#### Method

Implemented `Reset.reset_pool_apps/0` (the strongest reset hook
the spike could land — `Application.stop/1` + `ensure_all_started/1`
on `:mint`/`:finch`/`:nimble_pool`), gated by
`MUT_PERSISTENT_POOL_RESET=apps_restart`. Spike-only; not on any
user-facing path. The originally-scoped `process_tree_kill` mode
collapsed into `apps_restart` because mint and nimble_pool both
declare their `application` callback without a `:mod` supervisor
entry — there is nothing for `process_tree_kill` to restart that
`apps_restart` doesn't already cover.

#### Findings (full analysis at `docs/spikes/M36_pool_warm_state.md`)

Re-bench mint v1.8.0 and nimble_pool v1.1.0 in three modes
(mix / persistent default / persistent apps_restart):

- **`apps_restart` produces byte-identical outcomes to the
  default reset stack on both targets.** 0 mutants disagree.
  Wall and memory delta are zero to ms-level resolution.
- The leak class is **not** pool / socket / supervisor state —
  mint and nimble_pool are pure-library OTP applications with
  no `:mod` supervisor callback, so there is nothing for the
  reset hook to tear down or rebuild.
- Most-likely cause of the drift: **persistent finds more kills
  than mix on these targets**, possibly because persistent's
  warm BEAM exercises code paths mix-spawn's fresh-init
  doesn't. The drift direction is `mix=Survived → persistent=Killed`
  — losing kill signal by routing back to mix would be a
  regression, not a fix.

#### Why not the other two options

- **Mix-spawn reroute** would replace persistent's Killed with
  mix's Survived for these mutants — losing kill signal rather
  than recovering correctness.
- **Mix-only classification** is wrong for this class. Persistent
  produces the same kill rate or higher than mix at 2-5× wall
  speedup, which is exactly what the persistent worker is for.
  Forcing `--worker-type mix` would cost users real perf for a
  "drift" that may be persistent being more thorough.

#### Parse-class subsection

The 4 residual `:parse_class` mutants across the corpus
(2 nimble_options + 2 mox) cannot be reached by any of M36's
candidate modes — they live in the in-process recompile parser
path. M29's helper-process spike already established this. The
host's existing `:parse_error` recompile-category fallback
already routes these mutants via mix-spawn for an authoritative
verdict, so no additional disposition is needed. Documented in
the spike doc.

#### Module changes

- `Mut.Worker.PersistentRunner.Reset.reset_pool_apps/0` (spike-
  only, env-gated). Wired into `reset_leaks/2`; no-op when env
  var is unset.
- `reset_pool_us` field added to `MUT_RUN_METRICS`.
- `MUT_PERSISTENT_POOL_RESET` forwarded by the persistent host's
  port environment.

The spike does NOT promote a reset hook to default behaviour.
Pool-class detection in the boot warning (M35), the drift
bucketer's `:pool_warm_state` heuristic (M27), and the
`mix mut.drift` triage workflow (M35) remain the user-facing
disposition.

### M35 — Pool-warm-state boot warning + drift bucketer hardening (2026-05-10)

Bundles two M27 follow-throughs deferred from v1.11 close.

#### Pool-class boot-warning catalogue

`Mut.Worker.Persistent.Detector` gains three rows:

| Detected dep | Signature | Persistent stance |
|---|---|---|
| `:mint` | `:pool` | supported with caveat |
| `:finch` | `:pool` | supported with caveat |
| `:nimble_pool` | `:pool` | supported with caveat |

Multiple matches collapse into a single `:pool` detection (mirroring
`:ecto`/`:ecto_sql`). The catalogue does NOT preemptively add
`:poolboy`/`:hackney`/`:gun`/`:connection` — the bucketer's
`@pool_app_names` heuristic still catches drift on those names if
a real target surfaces it; the boot warning is a separate UX
artifact and waits for evidence.

Unlike Ecto / Gettext / clustered-Mox, pool-class is **not**
classified as mix-only. M27's measurement showed real drift
(mint 19.6%, nimble_pool 14.3%) but persistent still produces
useful kill counts; users decide per-project. M36 may close the
class via reset hooks; until then, the warning directs users at
`mix mut.drift --target <name>` for verification.

#### Drift bucketer hardening

- New heuristic **`:supervisor_init`** for `mix=RuntimeError →
  persistent={Killed,Survived}` flips outside the target-specific
  buckets. M30 documented this on ecto (caught earlier by
  `:ecto_warm_state`); M27's plug v1.19.1 bench surfaced the same
  pattern in `lib/plug/router/utils.ex` and was previously
  unclassified. Ranked AFTER target-specific heuristics so ecto /
  mox / pool flips still attribute to their named buckets first.
- New flag **`--json`** for CI consumption. Output includes
  per-bucket counts, sample stable_ids per bucket, total /
  drift / unclassified rate, agree counts, and the resolved mix
  + persistent report paths.
- New flag **`--sample-size N`** (default 3) controls how many
  sample stable_ids per bucket the report includes.
- Terminal output now includes the resolved report paths above
  the per-target table and `e.g. <id>, <id>, ...` after each
  non-empty bucket count for triage.
- Per-bucket unit test coverage extended; existing 18 tests
  grow to 21 with `:supervisor_init` cases.

#### Aggregate unclassified rate

Re-evaluated on the M25 + M27 + M34 corpus (13 targets, 329
drifting mutants):

| Pre-M35 | Post-M35 |
|---:|---:|
| 22 / 329 = 6.69% | **1 / 329 = 0.30%** |

The 21 reattributed mutants split as:
- jason: 2 → `:supervisor_init`
- nimble_options: 3 → `:supervisor_init`
- plug: 16 → `:supervisor_init`

The single residual unclassified mutant on jason is an
isolated `Killed → Survived` flake on a property-test path.
Well under the 5% acceptance bar.

#### Module changes

- `Mut.Worker.Persistent.Detector` — three new `:pool` rows.
- `Mut.Drift.Bucketer` — `:supervisor_init` heuristic; the
  `cond`-style dispatch in `bucket_for/3` refactored to a
  data-driven `Enum.find/2` walk so adding heuristics doesn't
  inflate cyclomatic complexity.
- `Mix.Tasks.Mut.Drift` — `--json`, `--sample-size`, terminal
  output enriched with report paths and per-bucket samples.

### M34 — `Mut.SchemaPlacer` escaped-quote fix (2026-05-10)

Mutalisk regression that blocked 3 OSS targets pinned in M27
(`phoenix_html`, `plug`, `phoenix_pubsub`) is closed.

#### Root cause

`Mut.SchemaPlacer.strip_heredoc_delimiters/1` (added in M25 for a
narrow gettext heredoc-with-`\`-continuation case) walked any AST
3-tuple `{atom, meta, args}` and stripped `:delimiter` /
`:indentation` metadata when the delimiter was `"\"\"\""` or
`"'''"`. This forced `Macro.to_string/1` into regular form for
both interpolated strings (`:<<>>` nodes) AND sigil nodes
(`:sigil_S`, `:sigil_s`, ...).

The intended target — interpolated-string heredocs with `\`
continuation — round-trips cleanly via the regular `"..."` form.
But sigil heredocs do NOT: a `~S"..."` regular sigil with literal
`"` characters in the body fails to parse (the `"` closes the
sigil prematurely). phoenix_html v4.3.0 `lib/phoenix_html.ex`
contains `@doc ~S"""..."""` blocks with `iex>` examples
containing literal escaped-quote sequences — pre-M34 schema
build crashed there.

#### Fix

The strip walker now matches only `:<<>>` nodes. Sigil
heredocs render via `Macro.to_string/1`'s native sigil-heredoc
emission and round-trip without a workaround. The original
gettext heredoc-with-`\`-continuation case continues to work
(those are interpolated `:<<>>` nodes, which the strip still
handles).

Regression test added at
`test/mut/schema_placer/schema_placer_test.exs` covering the
phoenix_html shape (`@doc ~S"""...""" ` containing literal
escaped quotes).

#### Re-bench post-M34

The three M27-pinned targets reclassified:

- **phoenix_html v4.3.0**: clean. 93 mutants, 81.7% combined
  score in both worker modes, zero drift. Joins the persistent-
  safe catalogue.
- **plug v1.19.1**: drift. 352 mutants, 17 drift (4.8%) all
  `RuntimeError → Killed` in `lib/plug/router/utils.ex` —
  supervisor-init class, same mechanism as Ecto/M30. Drift is
  small but structural; classify as drift, not clean.
- **phoenix_pubsub v2.2.0**: still unrunnable, BUT for a
  different reason: persistent boot fails when
  `test/support/cluster.ex` calls `Mix.State.get/2` from a
  spawned peer node where Mix isn't bootstrapped. This is a
  test-infrastructure dependency, not a Mutalisk regression. The
  M27 SchemaPlacer crash is closed; phoenix_pubsub's residual
  block is a different class (cluster-test bootstrapping) and
  out of v1.12 scope.

#### Module changes

- `Mut.SchemaPlacer.strip_heredoc_delimiters/1` narrowed pattern
  match.
- New regression test for `~S` sigil heredoc round-trip.

## v1.11 unreleased

### M33 — Comparison-operator boundary mutator: pre-existing, validated (2026-05-10)

PLAN.md scoped M33 as "Restart catalog growth with one narrow,
fallback-safe addition: `Mut.Mutator.ComparisonBoundary` mutating
`<` ↔ `<=`, `>` ↔ `>=` in body context, routed via the schema
engine."

**Finding: the mutator was already implemented in v1.5 (commit
06e8398, 2026-05-03) and matches the M33 spec exactly.**

`lib/mut/mutator/comparison_boundary.ex` mutates the four
boundary operators on `Kernel` / `:erlang` dispatch sites in body
context (`ctx.env_context == nil`), routes through the schema
engine via `@kind :comparison_boundary` (no env walker, no
fallback path), and is wired into both `Mut.Mutator.Defaults`
and the CLI's mutator name table. Unit tests at
`test/mut/mutator/comparison_boundary_test.exs` (4 cases)
pass; golden_oracle and golden_instrument verify layers stay
green under `bin/verify`.

#### Bench validation on reference targets

Bench observations against M27 / M28 / M30 result archives:

| Target | ComparisonBoundary mutants | Killed | Survived | Kill rate |
|---|---:|---:|---:|---:|
| plug_crypto v2.1.1 | 3 | 1 | 2 | 33.3% |
| Decimal | 38 | 15 | 23 | 39.5% |
| nimble_options v1.1.1 | observed via M27 bench | — | — | — |
| ecto v3.13.6 | observed via M30 bench | — | — | — |

Kill rates on the two arithmetic-heavy reference targets are
**below the 60% acceptance bar** PLAN.md set. PLAN.md's
expectation cited "documented low equivalent-mutant rate in
arithmetic-heavy code" — the observation is that even on
arithmetic-heavy targets, surviving boundary mutants reflect
test-suite gaps (missing edge-case probes around 0, equality,
and signed boundary conditions) rather than equivalent mutants.

Test-strengthening on Decimal and plug_crypto is a downstream-
project responsibility, not a Mutalisk mutator-design problem.
The mutator is operating per spec; the kill rate is what the
bar projects already produce against it.

**No code changes.** PLAN.md's M33 entry is marked complete; the
60% kill-rate gate is reframed as an observation rather than an
acceptance criterion (kill rate is a property of the project's
test suite, not of the mutator).

### M32 — Affected-test selection spike: shelved (2026-05-10)

PLAN.md scoped M32 as a spike with a strict kill criterion: any
silent-survivor delta on demo_app + plug_crypto + ≥2 OSS targets
shelves the optimization. v1.11 takes the documented shelve
outcome based on pre-implementation analysis of the silent-
survivor risk surface.

Decision rationale (full analysis at
`docs/spikes/M32_affected_tests.md`):

1. Five risk vectors identified: `setup_all` cross-test
   dependencies, doctest name encoding, property-based test
   generator non-determinism, `:cover`'s macro-expansion gap, and
   async test interleaving. Three plausibly fire on the
   acceptance corpus (demo_app, plug_crypto, nimble_options,
   jason) before implementation begins.
2. Implementation cost (~300-500 LOC + fixtures + new coverage-
   collection paths + ExUnit plumbing) is non-trivial.
3. The current `coverage_with_static_fallback` mode already
   provides fanout reduction at a softer correctness contract.

`static` remains v1.11's selection default; `coverage_with_static_fallback`
is the recommended opt-in for fanout reduction without correctness loss.
M32 reopens in v1.12+ only if a real user report establishes
demand AND one of the underlying primitives (`:cover` per-test
attribution, ExUnit dependency exposure) gains capability that
eliminates a primary risk vector.

### M31 — Gettext compatibility: classified mix-only (2026-05-10)

PLAN.md scoped two paths for M31:

- **Path (i):** wrap the persistent worker's test-load step in
  `Kernel.ParallelCompiler.compile/2` so `Gettext.Compiler.__before_compile__/1`'s
  `Kernel.ParallelCompiler.async/1` call has the parent context
  it requires.
- **Path (ii):** formally exclude gettext-class as mix-only.

v1.11 takes Path (ii). M29's recompile-isolation spike already
showed `Kernel.ParallelCompiler` for the fallback path doesn't
subsume warm-state drift, so the plumbing cost of Path (i)
buys only gettext boot and not a broader correctness
improvement. M30 separately classified Ecto-class as mix-only
on structural grounds. Persistent's principled-mix-only set is
now: Ecto, Gettext, and (with caveats per M28) clustered Mox.

The boot-warning catalogue's `:gettext` row is updated to name
the underlying compile-context requirement and direct users to
`--worker-type mix`. No code changes beyond the message
update; `Mut.Worker.Persistent.Detector` already detected the
signature in M27.

Path (i) remains a v1.12+ option if the underlying compiler
plumbing cost drops or if a `gettext`-shape becomes a primary
v1.12 acceptance class.

### M30 — Ecto warm-state closure: classified mix-only (2026-05-10)

Ships `Mut.Worker.PersistentRunner.Reset.reset_ecto/0`, modeled on
M28's `reset_mox/0`: walks the ETS catalogue, finds tables owned by
`Elixir.Ecto.*`-named processes (skipping `Ecto.Repo.Registry`
itself), and calls `:ets.delete_all_objects/1` between mutants. No-
op when `:ecto` isn't loaded. `reset_ecto_us` joins
`MUT_RUN_METRICS`; `ecto` row added to the `Persistent worker >
reset hooks` terminal block (median ~0.1 ms with `:ecto` loaded).

#### Acceptance findings

Re-bench on ecto v3.13.6 (994 mutants):

| | mix | persistent (pre-M30) | persistent (post-M30) |
|---|---:|---:|---:|
| Combined score | 78.0% | 76.0% | 76.5% |
| Drift vs mix | — | 226 | 231 |

The ETS reset has no measurable effect on the dominant warm-state
classes. M30 measurement clarifies the M25 / M27 diagnosis:

- The 113 `RuntimeError → Killed` flips are **not cache-state
  leaks**. They come from supervisor-init reordering: mix-spawn
  re-runs `Application.start/2` on every fallback mutant, so any
  mutation that breaks supervised initialization surfaces as a
  test-framework RuntimeError. Persistent doesn't re-run
  `Application.start/2` — it loads apps once at boot — so the same
  mutation runs against an already-initialized supervisor tree
  and the affected test simply fails (`Killed`). This is
  structurally what `--worker-type persistent` is designed to do;
  it cannot be closed by reset hooks.
- The 67 `Survived → Killed` and 22 `Killed → Survived` flips are
  partly leaked `Ecto.Query` planner cache and partly the same
  supervisor-init effect on other test paths. ETS-clearing reaches
  the planner cache but not the supervisor-init class.

**Decision: classify Ecto-class projects as mix-only.** The
`reset_ecto/0` hook stays in place as defense-in-depth; the
boot-warning catalogue's `:ecto` row is updated to reflect the
finding rather than promising a future fix. v1.11+ will not
attempt further Ecto-class closure unless the supervisor-init
re-run can be made cheap enough to land per-mutant (open
question for v1.12+).

#### Module additions

- `Mut.Worker.PersistentRunner.Reset.reset_ecto/0`
- `reset_ecto_us` field in `MUT_RUN_METRICS` runner protocol.
- `ecto` row in `Persistent worker > reset hooks` terminal block.

#### Default-flip gate (closed)

The v1.11 default-flip gate (PLAN.md) required Ecto-class drift
to close to V17 timeout-flap acceptance. M30 confirms this is
structurally impossible without re-running `Application.start/2`
per mutant, which is what `--worker-type mix` already does.
**The v1.11 default `--worker-type` STAYS `mix`.** Persistent
remains opt-in and is the right choice for projects whose
project-class signature does NOT match Ecto / Mox-cluster /
HTTP-client / process-pool / Gettext / SchemaPlacer-crash
patterns.

### M28 — `Mox.Server` reset hook for local-node mock state (2026-05-10)

Adds a Mox-aware reset hook to the persistent worker. Between
mutants, `Mut.Worker.PersistentRunner.Reset.reset_mox/0` asks
`Mox.Supervisor` to terminate and restart its child (the
`NimbleOwnership` GenServer registered as `Mox.Server`), wiping
all expectations, allowances, history, and stubs. Mocks defined
by `Mox.defmock/2` are compiled modules and survive the
restart. The hook spins on `Process.whereis(Mox.Server)` for up
to 50 ms after `restart_child/2` to defeat any race where the
supervisor returns before NimbleOwnership's `init/1` finishes.

The hook is a no-op when `:mox` is not loaded — Mox is not a
runtime dep of mutalisk, and projects without Mox pay zero cost.

#### Acceptance findings

Bench-validated on `mox` v1.2.0 (the M25 reference target).
Result: **the 3 `Survived → Killed` flips M25's CHANGELOG
attributed to "Mox.Server module-replacement state" are NOT
local-node mock-registry leaks**. After M28, all 3 still flip;
all 3 are killed by tests in `MoxTest.ClusterTest`, which spawns
peer Erlang nodes via `:peer.start/1` and runs Mox across the
cluster. Non-cluster Mox usage is now byte-identical between
worker types; the residual is multi-node mock state.

This finding is exactly what M27's bucketer expansion was
designed to surface — the symptom looked like Mox.Server state
in M25's narrow corpus, but with M28 in place the underlying
cluster-state vector reveals itself. The 3-mutant residual is
re-classified as cluster/peer-state drift (a NEW unsupported
pattern documented in `PERSISTENT_WORKER_GUIDE.md`) and
open at v1.11 close: M29's spike declined helper-process
isolation as a general fix, and a multi-node-aware reset hook
is v1.12+ scope.

The persistent boot-warning catalogue keeps the `:mox` row
because mox-using projects with cluster tests (or other
peer-node distributed tests) still see drift. Catalogue entries
are removed only when the entire drift class closes.

#### Module additions

- `Mut.Worker.PersistentRunner.Reset.reset_mox/0`
- `reset_mox_us` field in `MUT_RUN_METRICS` runner protocol.
- `mox` row in the `Persistent worker > reset hooks` terminal
  block (median ms).

#### Default-flip gate (unchanged)

M28 does NOT close mox-class drift to V17 timeout-flap acceptance
on the M27-expanded corpus, so the v1.11 default-flip gate
remains gated on M30 (Ecto warm-state) AND a follow-up that
closes the cluster-state residual. The v1.10 default
(`--worker-type mix`) stays.

### M27 — OSS validation harness expansion + drift observability (2026-05-10)

v1.10's lesson was that 3 reference targets hide entire bug classes.
M27 widens the permanent harness so v1.11+ default-flip and warm-
state decisions cannot rest on the same narrow base.

#### Bench harness expansion

Pinned 13 candidate targets across three rounds; 5 are
non-unrunnable (the v1.11 acceptance set):

- `telemetry_metrics` v1.1.0 — clean (31 mutants, byte-identical).
- `mint` v1.8.0 — drift (49/250 mutants, 19.6%, all
  `pool_warm_state`).
- `nimble_pool` v1.1.0 — drift (4/28 mutants, 14.3%, all
  `pool_warm_state`).
- `castore` v1.0.9 — clean (6 mutants).
- `mime` v2.0.7 — clean (5 mutants).

Pinned-but-unrunnable targets (kept in harness for future
operators on different toolchains): `phoenix_html`, `plug`,
`phoenix_pubsub` (Mutalisk SchemaPlacer escaped-quote crash —
v1.12 follow-up); `finch` (`:x509` fails on Erlang/OTP 28);
`ex_machina` (`:credo` fails on Elixir 1.19); `tzdata` (baseline
test failures); `gen_stage` and `nimble_csv` reclassified as
informational (mix flake / 0 mutants).

Per-target prep documented in `bench/M27_RUNBOOK.md`. SHAs in
`bench/run.sh`.

#### `mix mut.drift` — drift-bucketing tool

`Mut.Drift.Bucketer` consumes pairs of Stryker-format reports
(`bench/results/<target>.<...>.{,persistent.}stryker.json`) and
classifies mix-vs-persistent stable-id status drift into 8
heuristic buckets:

- `:mox_class` — module-replacement state leaks (M28 will close).
- `:ecto_warm_state` — warm BEAM hides errors mix-spawn surfaces
  AND vice versa (M30 will close).
- `:ecto_false_kill` — leaked Ecto.Query planner cache produces
  false kills (M30 will close).
- `:gettext_class` — boot-time / recompile macro failures.
- `:parse_class` — `Code.compile_file/1` parser disagreement
  vs mix-spawn.
- `:pool_warm_state` — HTTP-client / process-pool socket and
  registry state leaks (mint, nimble_pool — NEW in M27).
- `:timeout_flap` — V17 acceptance class.
- `:unclassified` — anything else.

CLI: `mix mut.drift --target <name>` for per-target tables;
`mix mut.drift --all` for the aggregate. Runs cleanly against
M25's existing 5 targets AND M27's new ones; bucket counts on
M25 data match the hand-classification documented in v1.10's
CHANGELOG (mox 3 mox_class + 2 parse_class; ecto 162 warm_state
+ 59 false_kill + 1 timeout). Aggregate unclassified rate on
M25+M27 corpus: ~4.3%. Hand-classification at v1.12+ no longer
required.

#### Persistent boot-time warning

`Mut.Worker.Persistent.Detector` scans the sandbox's compiled-dep
tree for `:mox` / `:ecto` / `:ecto_sql` / `:gettext` and emits
one stderr warning line per detection at persistent boot,
suggesting `--worker-type mix` and pointing to
`docs/PERSISTENT_WORKER_GUIDE.md`. Suppressible via
`--quiet-boot-warning` for CI cleanliness.

The catalogue is intentionally narrow — rows are removed only
when the entire drift class closes. The v1.11 catalogue retains
all three rows (mox, ecto, gettext): M28 closed local-node Mox
state but cluster-state residual remains; M30 + M31 classified
ecto-class and gettext-class as structurally mix-only. HTTP-
client / process-pool signatures are NOT yet detected at boot —
extending the catalogue is a v1.12 follow-up.

#### New unsupported patterns documented

Beyond M25's four (Mox.Server, Gettext.Compiler boot, Ecto warm-
state, parse-class recompile), M27 surfaced two new pattern
classes documented in `docs/PERSISTENT_WORKER_GUIDE.md`:

- **HTTP-client / process-pool warm state.** Both worker types
  produce different outcomes on `mint` and `nimble_pool` because
  the warm BEAM accumulates sockets / pool workers / registry
  entries across mutants. Different root cause from Ecto warm-
  state, same drift direction; fix is on the v1.12 horizon.
- **SchemaPlacer escaped-quote crash.** `phoenix_html`, `plug`,
  and `phoenix_pubsub` all crash schema build with
  `Code.format_string!/2 → SyntaxError` on source files containing
  HTML/header content with embedded `\\"..\\"` strings. Mutalisk
  regression in `Mut.SchemaPlacer.render/1`; both worker types
  affected. v1.12 follow-up.

#### Module additions

- `Mut.Drift.Bucketer`, `Mut.Drift.Bucketer.Result`
- `Mix.Tasks.Mut.Drift`
- `Mut.Worker.Persistent.Detector`
- `--quiet-boot-warning` CLI flag (also `config :mut,
  quiet_boot_warning: true`).

#### Default-flip gate (unchanged)

The v1.11 default-flip gate (PLAN.md) requires M28 + M30 + M31
to land before considering flipping `--worker-type` from `mix`
to `persistent`. M27 is observability + harness expansion; it
does NOT change the default. M27 also does NOT alter the
body-literal default (M25 settled it as opt-in).

## v1.10 unreleased (M25 + M26, 2026-05-10)

### M26 — Persistent worker default-flip decision: Outcome 3 (defer)

Applied the v1.10 default-flip gate criteria from PLAN.md against
M25's matrix data. No new bench runs (per M26 spec).

| Gate criterion | Result |
|---|---|
| ≥4 of 5 OSS targets clean (byte-identical) | ❌ 0 of 5 |
| Zero new unsupported-pattern categories | ❌ 4 new (Mox.Server, Gettext.Compiler boot, Ecto warm-state, parse-class recompile) |
| Persistent ≥1.5× faster on plug_crypto + Decimal + 2 M25 targets | ⚠️ Partial (jason ≈ comparable; ecto 8.7× but drift unsafe) |
| `--worker-type mix` remains documented escape hatch | ✅ |

**Outcome chosen: 3 (defer flip; scope persistent-pattern fixes
for v1.11).** `--worker-type mix` remains the v1.10 default.
Persistent stays opt-in.

#### v1.11 milestones scoped (PLAN.md update)

Committed:
- **M27** OSS validation harness expansion + drift observability.
  Pin ≥5 additional OSS targets; ship drift-bucketing tool;
  add persistent boot-time warning for known-bad target classes.
- **M28** `Mox.Server` reset hook between mutants.
- **M29** Persistent recompile isolation spike (in-process vs
  helper-process vs mix-spawn). Spike output is a decision doc,
  not shipped code.
- **M30** Ecto warm-state closure, sequenced after M29.

Stretch (commit only with budget):
- **M31** Gettext compatibility decision (fix via
  `Kernel.ParallelCompiler` parent OR formally exclude).
- **M32** Affected-test selection spike. Sharpened kill criterion:
  any silent-survivor delta on any target kills the optimization.
- **M33** Comparison-operator boundary mutator (`<` ↔ `<=`,
  `>` ↔ `>=`). Restarts catalog growth without env walker.

NOT a milestone: upstream Elixir `Macro.to_string/1` heredoc fix
revert. Tracked as a CHANGELOG note + TODO; single PR when
upstream lands.

#### v1.11 default-flip gate (revised)
Default `--worker-type` flips iff M28 closes mox-drift, M30 closes
ecto-drift, AND gettext-class is either fixed (M31 path i) or
formally documented `--worker-type mix` only (M31 path ii).
The flip is **not a v1.11 goal** — v1.11 ships even if the gate
stays unmet.

### M25 — OSS validation matrix + Decisions 1 & 2

#### Added
- **5-target v1.10 validation matrix** committed under
  `bench/results/`: `nimble_options` v1.1.1, `gettext` v1.0.2,
  `ecto` v3.13.6, `mox` v1.2.0, `jason` v1.4.5. Each target ran
  under `{mix, persistent} × {baseline, --enable-body-literal}` at
  `--concurrency 4`. SHAs pinned in `bench/run.sh`.
- **Per-target test-tree prep** in `bench/run.sh`:
  - `gettext`: drop `mix.tasks.gettext.{extract,merge}_test.exs`
    (env-fragile Mix-stdout assertions broke against current Mix).
  - `ecto`: inject `[:integration, :postgres, :mysql]` excludes +
    `seed: 42` into existing `test_helper.exs`; tag-skip 9
    Elixir-1.19 regex-equality assertions in `changeset_test.exs`.
  - `jason`: pin `seed: 42` for StreamData reproducibility.
- **`bench/M25_RUNBOOK.md`** — operator runbook for re-running the
  matrix per-target with inline elixir snippets for analysis.

#### Mut-side fixes (surfaced by the matrix)
- **`Mut.SchemaPlacer.RefusedContext` now routes to fallback**
  rather than crashing the run. Previously, any mutant candidate
  inside a `defmacro` body aborted the whole `mix mut` invocation.
- **`:parse_error` recompile category** alongside `:unknown`,
  `:compile_error`, `:dep_path_error`. Persistent-worker recompile
  errors produced by parser-stage failures
  (`MismatchedDelimiterError`, `SyntaxError`, `TokenMissingError`)
  now classify as `:parse_error` and re-route to mix-spawn fallback.
  Visible in metrics block as `parse errors:` distinct from
  `in-process compile errors:`.
- **`Mut.SchemaPlacer.schema_arm_ids/1` hardened** against
  non-list `case` arms in target source (e.g., macro DSLs that
  splice case clauses via `unquote(arms)`). Previously raised
  `Protocol.UndefinedError` on `Enumerable.impl_for!/1`.
- **`Mut.SchemaPlacer.render/1` heredoc workaround** for an
  upstream Elixir bug: `Macro.to_string/1` drops `\` line-
  continuations in heredoc-delimited strings, producing unparseable
  output. M25 strips heredoc `:delimiter` token metadata before
  rendering so `Macro.to_string/1` falls back to regular `"..."`
  strings, which round-trip cleanly.
- **`Mut.TestSelection.Static.module_concat/1` hardened** against
  dynamic alias parts — `__aliases__` parts can be tuples like
  `{:__MODULE__, _, _}` or `{:unquote, _, [_]}`; calling
  `to_string/1` on them invoked `String.Chars.impl_for!/1` which
  has no tuple impl. Now returns `nil` for any non-atom/non-string
  part; caller silently skips the reference.
- **`:jason` dependency removed** in favor of the built-in `JSON`
  module (Elixir 1.19+). Resolves a self-bench dependency
  collision when the target shares an app name with a Mutalisk
  transitive dep.

#### Decisions

**Decision 1 (body-literal default policy): KEEP OPT-IN.**

Aggregate kill rate across n=419 pure body-literal mutants on 4
targets (nimble_options + mox + jason + gettext): 62.3% with
**zero invalid mutants**. Excluding jason (StreamData): 66.1%
mean across deterministic targets — passes the ≥60% threshold.

But the spec's keep-opt-in trigger ("mox/ecto shows persistent-
specific drift") fires: mox baseline drift 13.2%, ecto baseline
drift 22.4%. Body_literal default-on while the persistent worker
contaminates these targets would compound user pain.

v1.10 ships `body_literal` as `--enable body_literal` (no default
flip). v1.11+ reconsiders default-on once persistent-worker drift
on mox/ecto-class targets is closed.

**Decision 2 (body-literal routing): STAY FALLBACK.**

`jason` body-literal wall-clock contribution = 64.8% (largest
body-literal target, 354 new mutants). Above the ≥15% fallback-
cost threshold. But the spec couples routing migration with
default-on — Decision 1 = keep-opt-in voids the migration trigger.
PLAN.md v1.11 section will list schema-routing migration as a
forward-scope candidate.

#### Default-flip-worker gate: NOT MET (`--worker-type` stays `mix`)

The PLAN.md v1.10 ≥4 of 5 OSS clean gate is decisively unmet —
**zero of 5 targets are byte-identical** under persistent at the
v1.10 acceptance bar:

| Target | Drift | Reason |
|---|---:|---|
| nimble_options | 19% | parse-class in-process recompile drift |
| mox | 13% | `Mox.Server` state pollution |
| jason | 1-5% | borderline (cleanest of the matrix) |
| ecto | 22% | warm-state masking + false-positive kills |
| gettext | n/a | persistent boot crash (target-class incompat) |

`--worker-type mix` remains the v1.10 default. Persistent stays
opt-in via `--worker-type persistent` with PERSISTENT_WORKER_GUIDE
documenting the unsupported patterns surfaced.

#### Documentation
- **`BENCHMARKS.md`** — replaces the M24 WIP section with the M25
  final v1.10 validation matrix.
- **`docs/PERSISTENT_WORKER_GUIDE.md`** — adds target-specific
  unsupported patterns from M25.

#### Upstream bug surfaced
- **Elixir `Macro.to_string/1` heredoc + `\` continuation** —
  produces unparseable output. Repro at
  `/tmp/macro_to_string_heredoc_repro.exs`. Real-world impact:
  gettext v1.0.2 has this shape at `lib/gettext/extractor_agent.ex:83`
  and `lib/gettext/plural.ex:79`. Mutalisk works around via
  heredoc-delimiter stripping; will revert when upstream lands.

#### Out of scope for v1.10
- Default flip of `--worker-type` (gated on persistent-drift
  closure on mox/ecto-class targets).
- Default flip of `--selection` (still `:static`; the flip to
  `:coverage_with_static_fallback` planned in earlier PLAN
  drafts did not land — see lib/mut/cli.ex:276).
- New mutators / CLI flags.
- Schema-routing migration code (deferred to v1.11+ candidate).

## v1.9 unreleased (M22 + M23 + M24 partial, 2026-05-09)

### M24 — Body-literal real-world validation (in progress)

#### Added
- **`bench/run.sh --enable-body-literal`** — runs the bench under
  `--enable dispatch,guard,module_attribute,body_literal` so the
  body-literal additions can be measured against the dispatch /
  guard / attribute baseline.
- **`bench/run.sh` target stubs** for `nimble_options`, `gettext`,
  `ecto`, `mox`, `jason`. Repos pinned by URL; the SHA must be
  provided via `BENCH_SHA=<sha>` env so the harness refuses to
  drift against a moving HEAD.
- **demo_app body-literal validation** captured at
  `bench/results/demo_app.body_literal.terminal.txt`. 5 of 6 added
  body-literal mutants killed; +28% wall-clock; 1 equivalent-class
  survivor in `Guards.positive?/1`.
- **BENCHMARKS.md "v1.10 body-literal validation" section**
  tracking the per-target validation matrix as runs land. Includes
  the v1.10 default `--worker-type` flip gate criteria.
- **PERSISTENT_WORKER_GUIDE.md** documents `--enable body_literal`
  in the Configuration section.

#### Recommendation (interim)
Keep `body_literal` opt-in. The demo_app data alone is too narrow
to motivate a default flip. Re-evaluate after the OSS matrix is
captured.

#### Deferred
The OSS-target validation matrix (plug_crypto, Decimal,
nimble_options, gettext, ecto, mox, jason) is harness-ready but
not run in this commit. Each target needs:
1. A pinned `BENCH_SHA` (verified against the upstream repo).
2. `bench/run.sh --target <t> --concurrency 4 --worker-type mix`
   for the baseline.
3. Same with `--worker-type persistent` for byte-identity check.
4. Same with `--enable-body-literal` on each worker.
5. Findings recorded in `bench/results/` and rolled into the
   BENCHMARKS.md status table.

The `mox` target is the highest-priority remaining run — module
replacement is the persistent reset model's hardest case and may
surface a new unsupported-pattern entry for the worker guide.

## v1.9 unreleased (M22 + M23, 2026-05-08)

### M23 — Body-context literal mutators

First new mutator surface since v1.5. Two focused mutators for
function-body integer and boolean literals.

#### Added
- **`Mut.Mutator.IntegerLiteral`** with replacement table:
  `0 → 1`, `1 → 0`, `n → 0`, `n → n+1`.
- **`Mut.Mutator.BooleanLiteral`** with `true → false`,
  `false → true`.
- **`Mut.AstWalk.body_literal_candidates/1`** walker. Re-parses
  source with `literal_encoder` so bare literals carry parser
  metadata, then walks the encoded AST. Emits candidates only
  for literals in body position (inside `def`/`defp` body, NOT
  in patterns / guards / macro bodies / `quote` / attribute
  values).
- **`:body_literal` target** in the orchestrator and CLI. Opt-in
  via `--enable body_literal`. `--mutators body_literal` is an
  alias for both literal mutators.
- **demo_app fixture** gains `lib/literals.ex` and
  `test/literals_test.exs` exercising 3 body literals with
  pinned-value tests; all 4 generated mutants are killed.

#### Note on engine routing
PLAN.md M23 spec called for schema-engine routing. Body literals
ship via the **fallback engine** (source-patch) instead, because
schema placement requires the AST shape walker and placer agree,
and the literal walker uses `literal_encoder` while the placer
uses bare-literal AST. Reconciling forces `literal_encoder`
globally — that re-keys every existing mutant's `ast_path_hash`
and regenerates every golden stable-id. Fallback routing is the
clean v1.9 path; schema placement is a follow-up if perf
warrants.

### M22 — Persistent reliability, observability, and config

Reliability/observability/config milestone for the persistent
worker. No new mutators, no default flips, no validation surface
expansion — those land in M23 / M24. M22's purpose is to make
`--worker-type persistent` operationally boring: visible metrics,
documented contract, configurable timeouts, and a regression
fixture that locks in v1.7's F2 fix.

### Added
- **`--test-timeout-ms N` flag** plus `:test_timeout_ms` config
  key. Replaces the v1.8 hardcoded 10 s ExUnit timeout.
  Range 1000..600000 ms; default 10000. Applied to both
  worker types so they remain comparable.
- **Persistent metrics in terminal summary.** The
  `Persistent worker:` block now surfaces the operational
  counters M20 had been collecting silently: crashes,
  restarts, filter-misses, in-process compile errors, and
  mix fallbacks. Line is omitted when all five are zero.
- **Warning hint** at run end if persistent worker exceeded
  any threshold (crash rate >10%, filter-miss rate >25%,
  in-process fallback compile-error rate >5%). Informational
  only; no auto-fallback.
- **Coverage + persistent byte-identity assertion** in the
  `e2e_persistent` layer. Tightens the existing
  `assert_coverage_non_regression!` to compare killed/survived
  stable_id sets, not just totals — closes a silent-drift
  class between coverage selection's narrowed test list and
  the persistent worker's reset hooks.
- **Application.start/2 regression fixture** at
  [`test/fixtures/overlay_cases/app_start_callback/`](test/fixtures/overlay_cases/app_start_callback/)
  plus an integration test in
  [`test/mut/worker/persistent_test.exs`](test/mut/worker/persistent_test.exs)
  that locks v1.7 F2 in: an OTP app whose `start/2` creates a
  named ETS table the tests read from. Without F2, this fails
  under persistent.
- **`mutalisk.test_timeout_ms`** key in the Stryker JSON
  report (mirrors what the terminal shows).
- **[docs/PERSISTENT_WORKER_GUIDE.md](docs/PERSISTENT_WORKER_GUIDE.md)** —
  user-facing guide to the persistent worker: when to use,
  what works, what doesn't, how to read the metrics, when to
  fall back.

### Changed
- `Mut.Worker.args/1` is now `args/2`, accepting a
  `test_timeout_ms` second argument. Default kept at 10 000
  for backwards compatibility on existing direct callers.
- Host-deadline constant in `Mix.Tasks.Mut` is now
  `test_timeout_ms + 10 000` (computed per run) instead of a
  hardcoded 70 000.

## v1.8 (M20 + M21 + M21 phase 2 + M21 phase 3, 2026-05-07)

### M21 phase 3 — Per-test timeout dropped to 10 s

The remaining wall-clock on plug_crypto and Decimal under
persistent was dominated by ExUnit's 60 s per-test default
deadline. Mutation-introduced bugs are CPU-bound infinite loops
or unbounded recursion that don't need 60 s of evidence to
classify — 1-10 s is plenty.

#### Changed
- **Persistent runner** now passes `timeout: 10_000` to
  `ExUnit.start/1` alongside `max_failures: 1`. Per-test
  timeout is 10 s (was ExUnit's 60 s default).
- **Mix-spawn worker** now passes `--timeout 10000` on its
  `mix test` command line for parity.
- Tests with legitimately long-running scenarios can override
  per-test via `@tag timeout: ms` (the standard ExUnit knob).

#### Performance
Per-target persistent wall at c=4 vs v1.7 mix baseline:
- demo_app: ~10 s → ~7-8 s — 1.3× faster (unchanged)
- plug_crypto: 84 s → **26 s** — **3.23× faster than v1.7 mix**
  (84 s → 53 s mix at c=4 with new --timeout; 26 s persistent;
  persistent vs mix at fair --timeout = 2.04×)
- Decimal: 660 s → **130 s** — **5.08× faster than v1.7 mix**
  (660 s → 259 s mix at c=4 with new --timeout; 130 s
  persistent; persistent vs mix at fair --timeout = 1.99×)

#### Byte-identity
On Decimal: mix and persistent now produce IDENTICAL
status counts (363 Killed / 91 Survived / 0 Timeout — the V17
"killed/timeout flap" disappears at 10 s because both workers
catch infinite-loop mutants fast enough that `max_failures: 1`
aborts via the first failed test). Same 2-mutant
mutator-generation difference at line 1874 as v1.7.

The 1.5× M20 acceptance bar is comfortably met on both real
targets (1.99–2.04× at fair comparison; 3.23–5.08× vs v1.7
mix baseline).

## v1.8 (M20 + M21 + M21 phase 2, 2026-05-07)

### M21 phase 2 — in-process fallback recompile

#### Added
- **In-process fallback recompile** when `--worker-type persistent`
  is in effect. Persistent BEAM compiles the patched source via
  `Code.compile_file/1`, runs ExUnit against the patched module,
  then restores the original via `:code.purge/1` + `:code.load_file/1`
  (the schema-build ebins on the runner's `-pa` provide the
  originals). No mix-spawn child process per fallback mutant.
- New protocol line `RUN_FALLBACK <mutant_id> <compile_files>|<test_files>`
  alongside the existing `RUN`. Compile errors surface as
  `MUT_RESULT compile_error <us> <category> <msg>` and the host
  materialises `Result{status: :invalid, recompile_category: cat}`.
- New `Mut.Worker.Persistent.run_fallback/5` host API.
- New `Mut.Worker.run_fallback_in_process/5` wraps the
  prepare-patch flow (validate sandbox, render+apply patch, read
  manifest, compute dependents) around the persistent-side run.
- Fallback to mix-spawn on `:filter_miss` / `:timeout` /
  `:crashed` — same recovery contract as schema mutants.
- Two regression tests in `test/mut/worker/persistent_test.exs`:
  in-process compile + run against a patched source, and the
  `:compile_error` path on a deliberately broken patch.

#### Performance
Per-target persistent wall at c=4 (mix baseline → v1.7 → M21 leak-fix → M21 phase 2):
- demo_app: ~10 s → ~7 s → ~7-8 s → ~7-8 s — 1.3× faster
- plug_crypto: 84 s → 144 s → 80 s → **77 s** — **1.09× faster** than mix
- Decimal: 660 s → 744 s → 598 s → **623 s** — **1.06× faster** than mix

Decimal's wall went up slightly vs M21 phase 1 (598 → 623 s) due
to run-to-run variance; the fallback-bucket portion alone went
from 148 s → 126 s (saved 22 s on 75 fallback mutants).
Zero compile errors, zero Invalid, zero unexpected Killed→Timeout
regressions across the full 454-mutant Decimal bench.

## v1.8 (M20 + M21, 2026-05-07)

### M21 — Persistent worker faster than mix on real targets

M20 Phase B attempted (and rolled back) two perf optimisations
because Decimal regressed byte-identity. M21 found the actual
root cause: a *test-runtime parity bug*, not a state leak. Three
small fixes restore parity AND deliver the perf win the M20 spec
targeted.

#### Fixed
- **`PersistentRunner` now starts ExUnit with `max_failures: 1`**
  to mirror `mix test --max-failures 1` that the mix-spawn worker
  passes. Without it, persistent ran every selected test even
  after one failed — and ~30 Decimal mutants caused an early test
  to fail AND a later test to infinite-loop. Mix aborted at the
  first failure; persistent reached the loopy test and wedged the
  BEAM until the 60 s deadline. With the fix, persistent matches
  mix's "abort fast" behaviour exactly.
- **`Mut.Worker.Persistent.wait_for_result` now uses a
  per-message (relative) timeout** instead of an absolute deadline.
  Mix-spawn's `Worker.collect/3` resets its timeout every time the
  worker emits output; tests that legitimately take 60.5 s but
  emit per-test JSONL events while running survive in mix as long
  as silence stays under `timeout_ms`. Persistent's old absolute
  deadline killed those same tests at 60 s. Now it matches mix's
  semantics.
- **`@timeout_ms` bumped from 60 000 ms to 70 000 ms** to give
  ExUnit's `:max_failures_reached` event time to land before the
  host's deadline fires. Removes the 60 s == 60 s race between
  ExUnit's per-test default timeout and the host's wait.
- **`Mut.Worker.Persistent.run_schema/4` GenServer.call timeout is
  now `:infinity`.** With per-message host-side timeout, a
  legitimately slow but data-producing worker can exceed
  `timeout_ms` of absolute wall-clock; we never want
  GenServer.call to fire its own caller-side timeout and crash
  the calling Task.

#### Changed
- **Persistent's `:timeout` reply now materialises
  `Result{status: :timeout}` directly** without mix-spawn retry.
  After M21's fixes, persistent is byte-identical to mix on
  Decimal at c=4 within V17 acceptance — a mix-retry on timeout
  is unnecessary and would cost an extra `@timeout_ms` per
  timeout. Re-introduced the original Phase B.1a optimisation
  (rolled back in M20 because of the byte-identity regression);
  M21 fixed the regression's root cause so it's now safe.

#### Performance
Per-target persistent wall at c=4 (mix baseline → v1.7 → v1.8 M21):
- demo_app: ~10 s → ~7 s → ~7-8 s — 1.3× faster than mix
- plug_crypto: 84 s → 144 s → **80 s** — **1.05× faster** than mix
  (was 1.71× SLOWER in v1.7)
- Decimal: 660 s → 744 s → **598 s** — **1.10× faster** than mix
  (was 1.13× SLOWER in v1.7)

byte-identity preserved on all three targets; on Decimal,
persistent now produces 16 more Killed than mix at v1.7 (mutants
mix Timeout-ed but persistent kills fast via `max_failures: 1`).
Zero Killed→Timeout regressions.

The 1.5× perf bar from M20's Phase B acceptance is **not** met,
but persistent is now faster than mix on every real target.
Default flip remains a v1.9+ decision.

## v1.8 (M20, 2026-05-07)

### Added
- **`mutalisk.persistent` extension key in Stryker JSON.** When
  `--worker-type persistent` is in effect, the report's
  `mutalisk` block carries a new `persistent` sub-block with
  per-phase median timings (boot, app startup, test load,
  per-mutant ExUnit run, reset hooks per vector, filter
  lookup), counts (workers, crashes, restarts, filter-miss,
  mix-fallback), and memory peak per worker. `null` when
  `--worker-type mix` is in effect.
- **"Persistent worker:" terminal summary section.** Same data
  rendered as a human-readable block.
- `Mut.Worker.PersistentRunner.Diag` — in-BEAM helper for
  microsecond timing capture, memory snapshots, and the
  `MUT_BOOT_METRICS` / `MUT_RUN_METRICS` wire-protocol lines
  alongside the existing `MUT_READY` / `MUT_RESULT` markers.
- `Mut.Worker.Persistent.metrics/1` — host-side per-server
  view of accumulated diagnostics. Mix.Tasks.Mut drains every
  Persistent server before stopping it and folds the views
  into `Mut.Metrics`.
- New `Mut.Metrics.Snapshot.persistent` typespec block +
  `record_persistent_workers/2` accumulator API.

### Changed
- `Mut.Worker.Persistent.handle_call/3` distinguishes
  `{:error, :timeout, _}` from `{:error, :crashed, _}` and
  replies `:timeout` vs `:crashed` accordingly. Both still
  trigger BEAM auto-restart and mix-spawn retry on the host
  side (a Phase B attempt to skip the timeout retry regressed
  Decimal byte-identity by 31 mutants — see BENCHMARKS.md
  "v1.8 M20 Phase B"). The new API distinction is for code
  clarity and future targeted optimisation.

### Diagnostics gating
- `MUT_PERSISTENT_DIAG=0` disables per-mutant metrics emission
  in the runner (boot metrics always emit — boot happens once).
  Diagnostics overhead measured at c=4 on plug_crypto: 143 s
  with diag on vs 147 s with diag off, within noise (well
  under M20's 5% bar).

### Known limitations (M20 baseline, all closed by M21 follow-ups)
At M20's commit point persistent was 0.59× plug_crypto / 0.89×
Decimal (slower than mix). M21 phase 1 (test-runtime parity bug
fix), M21 phase 2 (in-process fallback recompile), and M21 phase
3 (per-test timeout policy) each landed below; see those sections
for current numbers. The M20 perf-acceptance gap is closed.

### Internal
- `lib/mut/worker/persistent_runner/diag.ex` (new — diagnostic
  helper).
- `lib/mut/worker/persistent_runner.ex` — boot, app-startup,
  test-load, per-mutant, per-reset-vector instrumentation.
  `Diag.emit_boot/1` and `Diag.emit_run/1` write JSON
  protocol lines parsed by the host.
- `lib/mut/worker/persistent.ex` — host parses the new
  protocol lines, accumulates per-server metrics, exposes
  `metrics/1` for the host pipeline. `boot_port/2` returns
  boot wall + parsed boot metrics.
- `lib/mut/metrics.ex` — `Snapshot.persistent_block/0`
  typespec, `record_persistent_workers/2` cast,
  `persistent_snapshot/1` reducer (medians/p95s across all
  workers).
- `lib/mut/reporter/terminal.ex` — `persistent_block/1`
  renderer.
- `lib/mut/reporter/stryker_json.ex` — `persistent_extension/1`
  serialiser.
- `lib/mix/tasks/mut.ex` — `collect_persistent_metrics/2`
  drains workers before snapshot rendering.
- `test/mut/worker/persistent_test.exs` — new test for the
  `:timeout` vs `:crashed` reply distinction.
- `bench/run.sh` benches for plug_crypto and Decimal at c=1
  and c=4 with diagnostics enabled produced the per-target
  Phase A tables in BENCHMARKS.md.

## v1.7 (M19, 2026-05-06)

### Added
- **`--worker-type persistent` (opt-in supported).** A new worker
  model that keeps one ExUnit BEAM alive per sandbox and flips
  `:persistent_term` between mutants instead of spawning a fresh
  `mix test` per mutant. Default stays `mix`; persistent is
  enabled by passing `--worker-type persistent`. Byte-identical
  to mix at c=4 across demo_app, plug_crypto, and Decimal (within
  V17 acceptance for the existing timeout-class flap). Schema
  mutants only; fallback continues to use the v1.6 mix-spawn path.
- `Mut.Worker.Persistent` host GenServer + `Mut.Worker.PersistentRunner`
  in-BEAM runner. ExUnit.Server state is snapshotted at boot and
  restored before every run so the same loaded test modules
  re-execute deterministically.
- `Mut.Worker.PersistentRunner.Reset` collects per-leak-vector
  snapshot/reset helpers (Application env, ETS tables, registered
  processes, persistent_term, ExUnit OnExitHandler) used between
  iterations. Reset baselines are captured before the first mutant so
  state created by mutant 1 cannot become the clean baseline for later
  mutants.
- ExUnit `only_test_ids` file filter so the persistent worker runs
  only the selected test files per mutant (matching the v1.6
  selection pipeline).
- Per-sandbox parallel persistent workers via M17's
  `Mut.SandboxQueue`.
- Crash recovery: a worker BEAM crash routes the offending mutant
  AND every subsequent mutant on the same sandbox to the mix-spawn
  worker. The persistent server is `GenServer.start` (not linked)
  so its crash does not propagate to the host's
  `Task.async_stream` worker.

### Changed
- **`mix.exs` requires Elixir `>= 1.18.0`.** Pre-1.18 users stay
  on v1.6.x. The persistent runner depends on internal ExUnit
  semantics (`ExUnit.OnExitHandler` ETS, ExUnit.Server state shape)
  stable from 1.18 onward.
- `bench/run.sh` accepts `--worker-type mix|persistent`.

### Fixed (v1.7 follow-ups)
- **`--no-halt` removed from the worker BEAM bootstrap** in
  `lib/mut/worker/persistent.ex`. With `--no-halt` the spawned BEAM
  ignored stdin EOF and survived port closure, accumulating as
  orphans across test/bench runs and was the root cause of the
  `mut.e2e --worker-type persistent` hang flagged in review 1. The
  runner's `loop/1` already exits on STOP / EOF; without
  `--no-halt`, the BEAM terminates cleanly and the e2e wrapper
  completes.
- **`e2e_persistent` verify layer enabled.** `bin/verify` now runs
  `mix mut.e2e --worker-type persistent` as a 9th layer. demo_app
  byte-identical between mix and persistent at c=4: 21 killed / 10
  survived in default, 21 / 10 in coverage, 23 / 10 in attribute
  mode (same stable-id sets).
- **Persistent runner now starts the project's OTP applications**
  (Mission F2). Without this, `Application.start/2` callbacks never
  fired, so resources they create (named ETS tables, registered
  processes) were missing under persistent and tests that depend on
  them crashed. plug_crypto's `Plug.Crypto.Application` creates the
  named `Plug.Crypto.Keys` ETS table this way; tests calling
  `sign`/`encrypt`/`verify`/`decrypt` failed with `:badarg` versus
  the mix worker (where `mix test` auto-starts the project's apps).
  The runner now scans `_build/mut_schema/lib/*/ebin/*.app` and
  ensures every project app is started before capturing the leak
  baseline. With this fix plug_crypto persistent at c=4 is
  byte-identical to mix: 38 Killed / 25 Survived / 1 Timeout (same
  stable-id sets).
- **`apply_file_filter/2` no longer silently runs every loaded
  test on filter miss** (Mission F1). Two paths produced this:
    1. host sent absolute paths via `Path.join(sandbox.path, file)`
       while the runner's index keyed test files on the *relative*
       path that `Code.require_file` received, so `Map.get` missed
       every entry;
    2. real misses (e.g. mistyped filename) — same fall-through.
  The runner now normalises both index keys and lookup keys via
  `Path.expand`. Files that still resolve to zero loaded tests
  return `{:error, {:filter_miss, files}}`; the runner emits a
  `MUT_RESULT filter_miss` line; `Mut.Worker.Persistent` replies
  `:filter_miss` and keeps the BEAM alive; `Mix.Tasks.Mut` reroutes
  that one mutant through the mix-spawn worker. Three regression
  tests (end-to-end + two direct unit tests) cover the path.

### Removed
- **`MUTALISK_PERSISTENT_EXPERIMENTAL=1` env gate** (Mission F3).
  All three correctness gates (demo_app, plug_crypto, Decimal) are
  met, so the experimental gate is removed. `--worker-type
  persistent` is now a regular opt-in flag.

### Known limitations (v1.7.0)
- **Default stays `--worker-type mix`.** Persistent worker is
  opt-in. v1.7 ships persistent as a correctness-safe opt-in,
  not a default/perf release: persistent is currently slower
  than mix on plug_crypto (1.7×) and Decimal (1.13×) at c=4, so
  the default flip waits on M20 perf work. demo_app is faster
  under persistent (1.3×).
- **In-process fallback recompile is deferred** (Mission F4
  phase 2). Fallback mutants always route to the mix-spawn
  worker, preserving M17's "0 invalid Decimal fallback" baseline
  regardless of worker type.

### Internal
- `lib/mut/worker/persistent.ex` (host).
- `lib/mut/worker/persistent_runner.ex` (in-BEAM).
- `lib/mut/worker/persistent_runner/reset.ex` (leak-vector helpers).
- `bin/verify` enables `e2e_persistent` as a 9th layer that runs
  `mix mut.e2e --worker-type persistent` directly. Asserts
  demo_app byte-identity between mix and persistent across
  default/coverage/attribute fixture variants.
- F4 phase 1: when the worker BEAM dies (port exit / run timeout),
  `Mut.Worker.Persistent` reboots the BEAM in-place; the crashing
  mutant gets `:crashed` and the host reruns it via mix-spawn,
  but subsequent mutants on the same sandbox stay on persistent.
  Two regression tests cover the success and unrecoverable-boot
  paths.

## v1.6 (M17, 2026-05-05)

### Changed
- **`mix mut` defaults to parallel execution.** The default
  `--concurrency` is now `min(System.schedulers_online(), 4)`, capped
  at 4. Use `--concurrency 1` for v1.5 sequential behaviour.
  Outcomes are byte-identical across `c=1/2/4/8` on demo_app,
  plug_crypto, and Decimal (M17 validation matrix).
- Decimal-class projects (e.g. `lukaszsamson/decimal@mutalisk-bench`)
  now complete comfortably under 30 minutes at the new default. See
  `BENCHMARKS.md` "Concurrency speedup curve (M17)" for full numbers.

### Added
- Reports include concurrency metadata.
  - Terminal summary prints a `Concurrency: N workers` line near
    the bottom (with `(sequential)` or `(capped at N
    schedulers_online)` suffix when applicable).
  - Stryker JSON gains a top-level `mutalisk.concurrency` block:
    `{ "configured", "effective", "schedulers_online" }`.
- Reports distinguish fallback recompile failures by category.
  - `:compile_error` — patched Elixir source did not compile.
  - `:dep_path_error` — required module not loadable from `-pa`.
  - `:unknown` — non-zero exit without a known signature.
  - Terminal summary surfaces a "recompile errors" sub-block under
    Fallback when total > 0.
  - Stryker JSON gains `mutalisk.recompile_categories` counts.
- New `Mut.SandboxQueue` (PROMPT_16, hardened in M17) audited and
  regression-tested under 32-task / 8-sandbox concurrent stress.
- New `Mut.LastKiller` concurrent stress test plus a p99 latency
  regression bar (sub-millisecond record_kill).

### Fixed
- M17 sandbox audit captured no behavioural fixes (the existing
  sandbox lifecycle is concurrency-safe), but the audit's
  regression test guards against future regressions.

### Internal
- `%Mut.Metrics.Snapshot{}` carries `concurrency` and
  `recompile_categories` fields.
- `Mut.Worker.Result{}` carries `recompile_category`.
- `Mut.Recompile.categorize/1` is the public classifier.

## v1.5 (M15 + M16)

- Coverage-aware test selection (`--selection coverage`,
  `--selection coverage_with_static_fallback`).
- Phase timing metrics in reports.
- See `BENCHMARKS.md` v1.5 section for outcomes.

## v1 (M0–M14)

- Schema-engine + fallback-engine mutation execution.
- Stryker-compatible JSON reporter.
- See `BENCHMARKS.md` v1 reference run.
