# Mutalisk Benchmarks

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

