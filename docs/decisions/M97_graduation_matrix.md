# M97 — Sharded matrix run + graduation decisions (v1.27)

**Date:** 2026-06-02

Decision: **FunctionReplace graduates to default-on** — the fourth new
graduation since M46 (after IntegerLiteral-in-pattern M63, ConcatOperator
M79, Pin M83). Everything else stays `keep_opt_in`, now with **real
measured data** rather than the structural arguments M93/M95 deferred to.

## The sharding strategy (what made the matrix actually run)

M93 and M95 both deferred the matrix on session-envelope grounds. The
binding cost was never the mutation runs — it was **clone + deps.get +
compile per target**, paid once per target but blown up when the prior
attempts re-cloned per (surface, target) cell.

`bench/shard_matrix.sh` fixes this: **shard = one target.** Clone +
deps + compile **once** into a persistent `tmp/bench/shard/<target>`
(a `.shard_ready` flag makes re-runs skip straight to mutation), then
loop each surface as a focused `mix mut --enable <flag> --mutators
<name> --max-mutants N` against the compiled work_copy. Each surface
generates only its own candidates and is bounded, so per-cell cost is
just coverage-collection + ≤N mutants.

The remaining bottleneck, surfaced by this run: **per-surface coverage
re-collection** on large suites (bandit's 653-test suite collects
`:cover` data per-test-file, ~8 min per surface). The harness handles
this with a per-surface `timeout 900` and a `--selection static`
escape for surfaces where the covered-survivor equiv metric isn't the
gating question (kill% + invalid% + candidate-count suffice).

## Matrix data (coverage_with_static_fallback, `--concurrency 1`, `--max-mutants 40`)

| surface | decimal | jason | bandit | prior (M79/M82/M88) |
|---|---|---|---|---|
| **FunctionReplace** | n=0 | n=0 | **88.9 / 11.1 / 0** | plug 100/0/0; absinthe 83.3/16.7/0 |
| NegateConditional | 76.9 / 23.1 / 0 | 47.6 / 52.4 / 0 | — | (M83: jason 47.6/52.4) |
| StatementDelete | 100 / 0 / 0 (n=1) | 100 / 0 / 0 (n=6) | — | (M83: plug_crypto 75/25/**20**) |
| ClauseDelete | 87.5 / 12.5 / 0 | 77.8 / 22.2 / 0 | — | (M88: plug 73.2/26.8/0) |
| GuardBoolean | n=0 | n=0 | (static, below) | first-eval |
| PipelineDropStage | 100 / 0 / 0 (n=2) | 100 / 0 / **66.7** (n=3) | — | first-eval |
| MapUpdateDrop | 50 / **50** / 0 | 100 / 0 / 0 (n=2) | — | first-eval |
| ReceiveTimeout | n=0 | n=0 | (static, below) | first-eval |
| Pin | n=0 | n=0 | — | default-on (M83: plug/absinthe/phoenix_html all 100/0/0) |

(Format: kill% / equiv% / invalid%. `n=0` = the target has no candidates
for that surface — decimal is pure arithmetic, jason is iodata-based.)

## Per-surface decisions

### FunctionReplace → **GRADUATE**

The recurring "needs a third runnable target" blocker (M79/M83/M88/M95
all kept it opt-in *for lack of breadth*, never for quality) is finally
gone. M91 wired bandit, which has FunctionReplace call sites. Three
coverage targets, all clear the M62 gate:

| target | n | kill% | equiv% | invalid% |
|---|--:|--:|--:|--:|
| plug | 13 | 100 | 0 | 0 |
| absinthe | 27 | 83.3 | 16.7 | 0 |
| bandit | 9 | 88.9 | 11.1 | 0 |

kill ≥60 ✓ everywhere; equiv <20 ✓ everywhere (max 16.7); invalid <10 ✓
(0 everywhere). The closed-allowlist design (Enum.min↔max, filter↔reject,
…; same arity, same module) is semantically safe by construction — the
equiv it does produce is the genuine "swap the suite doesn't
distinguish" class, bounded low. **Graduate.**

**Wiring.** `Mut.Mutator.FunctionReplace` moves from `@opt_in` to
`@default_on`; the CLI mirror `@default_on_mutators` gains
`"function_replace"`. Its target `:dispatch` is already in
`@default_enabled_targets`, so no target change (unlike Pin's
`:pattern_shape` in M83). **Additive + byte-identical:** demo_app has
zero allowlisted call sites (grep-confirmed) and Decimal's `fr` surface
is n=0 — both default plans unchanged (golden_oracle + golden_instrument
green).

### NegateConditional → keep_opt_in (M89 hazard measured, doesn't clear)

**Honest finding: the M89 symmetric-branches hazard did not move jason.**
jason `nc` is 47.6 / 52.4 — *identical* to M83. jason's 52.4% survivors
aren't structurally-identical do/else branches (which `symmetric_branches?/1`
gates) — they're branches that compute *different* values the test
suite's assertions don't distinguish (observational equivalence under
the suite, undecidable). The M89 hazard is correct — it removes true
symmetric-branch noise — but jason simply didn't have that shape.
decimal `nc` 76.9 / 23.1 is the dead-branch class (already gated by M80,
still 23%). Fails equiv on both measured targets. keep_opt_in.

### StatementDelete → keep_opt_in (clean but unverified on the problem target)

decimal 100/0/0 (n=1), jason 100/0/0 (n=6) — both clean, both clear. But
n is tiny, and the M83 problem target was **plug_crypto** (75/25/**20%
invalid**), which the M89 unused-binding hazard was designed to fix and
which this run did **not** measure (plug_crypto coverage is in the
slow-suite class; deferred). Two small clean targets aren't enough to
graduate the catalogue's noisiest surface without confirming the invalid
class is fixed on the target that exhibited it. keep_opt_in; the
plug_crypto unused-binding verification is the v1.28 carry.

### ClauseDelete → keep_opt_in (M89 error-only helped, not enough)

decimal improved 82.5/17.5 (M88) → **87.5/12.5** (M97) — the M89
error-only-clause hazard works. But jason 77.8/**22.2** (fail by 2.2pp
beyond tolerance) and plug 26.8% (M88) both still exceed the gate.
Clears on 1 of 3, fails on 2. keep_opt_in.

### PipelineDropStage → first-eval keep_opt_in (**invalid-hazard surfaced**)

decimal 100/0/0 (n=2) clean, but jason **66.7% invalid** (n=3 — 2 of 3
are CompileErrors). Dropping a `|>` stage produces a compile error when
the next stage requires the dropped stage's output *type* (e.g. dropping
a `to_string`/`Enum.to_list` whose result the next stage pattern-matches
or calls a type-specific function on). This is a real **invalid-hazard
carry** analogous to M89's StatementDelete unused-binding: the collector
should skip stages whose output type the downstream stage structurally
requires. v1.28+ refinement. keep_opt_in.

### MapUpdateDrop → first-eval keep_opt_in (ungated-equiv confirmed noisy)

decimal **50% equiv** (n=30), jason 0% (n=2). The "result not
bound/returned" hazard I deliberately left ungated in M94 (parent
context not statically visible) shows as exactly the predicted noise on
decimal. Target-dependent and noisy. keep_opt_in; a context-aware
equiv hazard is the refinement if this surface is ever pursued.

### GuardBoolean, ReceiveTimeout → first-eval keep_opt_in

n=0 on decimal + jason (neither has boolean-op guards or `receive`).
bandit (a server) is the only measured target that exercises them; data
collected under `--selection static` (below) for candidate-count +
kill/invalid. Informational first-eval; both stay opt-in regardless.

### Pin → stays default-on (no regression)

decimal/jason have no pins (n=0). Pin's M83 graduation rests on
plug/absinthe/phoenix_html (all 100/0/0); no regression-class indicator.
Unchanged.

## bandit GuardBoolean / ReceiveTimeout (static)

| surface | n | kill% | equiv% | invalid% | err |
|---|--:|--:|--:|--:|--:|
| GuardBoolean | 0 | — | — | — | — |
| ReceiveTimeout | 27 | 55.6 | 44.4 | 0 | **18** |

- **GuardBoolean: n=0 on all three measured targets** (decimal, jason,
  bandit). The finding: boolean connectives inside `when` guards are
  **rare in practice** — guards overwhelmingly use comparison +
  type-test (which the default-on Guard* mutators already cover).
  GuardBoolean is a structurally-valid but practically-near-empty
  surface. keep_opt_in (nothing to graduate — no candidates anywhere).

- **ReceiveTimeout: noisy on real concurrent code.** 18 of 27 mutants
  are RuntimeErrors — mutating a `receive ... after t` timeout to `0`
  (immediate return → downstream crash), `:infinity` (hang → test
  timeout → error), or dropping the `after` (lost safety net → hang)
  produces *errors*, not clean behavioral kills. Among the 9 behavioral
  verdicts, kill is 55.6% (below the 60 floor). The high error rate is
  intrinsic to the surface (a timeout mutator on a server manifests as
  crashes/hangs), not a fixable hazard. keep_opt_in. (equiv% is the
  static-selection covered-survivor reading; the err class dominates
  the signal regardless.)

## Additivity invariant

Only FunctionReplace graduated. It's additive: new swap mutants only,
existing stable IDs untouched. demo_app (no allowlisted calls) +
Decimal (`fr` n=0) default plans byte-identical — golden_oracle +
golden_instrument green. No other `@default_on` / `@default_enabled_targets`
change.

## Carried forward (v1.28)

- **plug_crypto StatementDelete** unused-binding verification (the M83
  20%-invalid target, unmeasured here on coverage-slowness grounds).
- **PipelineDropStage output-type invalid-hazard** (jason 66.7% invalid).
- **MapUpdateDrop context-aware equiv-hazard** (decimal 50% equiv).
- NegateConditional observational-equivalence is undecidable — no
  further hazard will move jason's 52.4% without semantic analysis
  outside mutalisk's design.
- The wider matrix (gettext/ecto/credo/makeup/timex/phoenix/LV) was not
  run — the fast/small + bandit shards gave the decisive data
  (FunctionReplace's third target) within the envelope; the rest is
  diminishing returns for surfaces already decided keep_opt_in.
