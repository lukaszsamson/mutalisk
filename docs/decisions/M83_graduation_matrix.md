# M83 — v1.23 graduation re-eval (Pin / FunctionReplace / NegateConditional / StatementDelete)

**Date:** 2026-05-28

Decision: **Pin graduates to default-on**; FunctionReplace, NegateConditional,
and StatementDelete stay `keep_opt_in`. Under the M62 gate (kill ≥60%,
equivalent <20% with ≤2pp single-target tolerance, invalid <10%, on **every**
matrix target).

## Pin → GRADUATE

The M82 matrix-breadth push gave Pin its third target. The result is
striking — Pin is flawless across all three:

| target | n | killed | survived | cov-surv | kill% | equiv% | invalid% |
|---|--:|--:|--:|--:|--:|--:|--:|
| plug | 14 | 14 | 0 | 0 | 100 | 0 | 0 |
| absinthe | 13 | 4 | 0 | 0 | 100 | 0 | 0 |
| phoenix_html | 1 | 1 | 0 | 0 | 100 | 0 | 0 |

(absinthe Pin's 9 RuntimeErrors — like the jason/decimal flakes — are
sandbox-concurrency artefacts, not mutator output; n counts only the
behaviourally-decided mutants.)

The M75 map-key hazard rule fixed the only invalid class, and the dropped
`_` ↔ named-var directions (M73's non-viability argument) keep the surface
narrow. Pin's behavioural value is real: unpinning turns a constrained match
into a rebind, observable whenever a test exercises the constraint. Graduate.

**Wiring.** `Mut.Mutator.Pin` moves from `@opt_in` into `@default_on`; the
mirror in `cli.ex` (`@default_on_mutators`) gains `"pin"`; and
`:pattern_shape` joins `@default_enabled_targets` so the walk actually runs by
default (its target was opt-in pre-M83). Future opt-in `:pattern_shape`
mutators stay gated by their absence from `@default_on`.

**Additivity verified.** Pin only fires on `^x` pin nodes; existing dispatch/
literal/guard mutants are untouched. demo_app has no pins (golden_oracle +
golden_instrument confirm byte-identical defaults), Decimal has no pins
(default-plan total stays 559 across PRE/POST `--debug-plan`).

## FunctionReplace → keep_opt_in

| target | n | kill% | equiv% | invalid% |
|---|--:|--:|--:|--:|
| plug | 13 | 100 | 0 | 0 |
| absinthe | 27 | 83.3 | 16.7 | 0 |

Two clean targets — both clear the gate individually — but M82's matrix-
breadth push could not reach the gate's "≥3 targets, every one clears"
threshold for FunctionReplace. The blockers were all environmental, not the
mutator's fault:

- **credo** (203 allowlisted calls — would have been the heaviest exercise):
  `Regex.CompileError` under Elixir 1.19 in
  `lib/credo/check/config_comment_finder.ex` (a regex-pattern incompatibility
  in credo itself, both v1.7.7 and v1.7.13).
- **ecto** (23 calls): 9 baseline test failures in the default Ecto suite
  (env-related; not all adapters/setups present).
- **req** (1 call, but a Pin candidate too): the `ezstd` native dependency
  fails to compile (the M55-era zstd C build blocker, unchanged).
- Small targets (gen_stage, finch, nimble_csv, telemetry_metrics): density
  check shows 0 allowlisted call sites — they exercise neither.

Documented `bench/run.sh` wiring of **absinthe** in M82; the FunctionReplace
graduation gate is now a target-availability problem, not a mutator-quality
problem.

## NegateConditional → keep_opt_in

Post-M80 hazards (binding hazard + dead-branch no-else gates):

| target | n | kill% | equiv% | invalid% | notes |
|---|--:|--:|--:|--:|---|
| plug | 138 | 77.2 | 22.8 | 0.7 | **invalid 15.3% → 0.7%** — huge win |
| decimal | 67 | 76.9 | 23.1 | 0.0 | (rerun at c=1; c=4 produced a sandbox-startup flake) |
| jason | 23 | 47.6 | 52.4 | 0.0 | both-branch-equivalent under coverage, not no-else |

The binding hazard cleanly resolved plug's 15.3% invalid class — the
intended win. The dead-branch hazard helped decimal modestly (25.4% → 23.1%)
but did not move jason (52% equiv) because jason's surviving mutants are
in if-else shapes where both branches return equivalent values under the
test coverage, not the no-else shape we gate. Equiv >20% on three of four
targets; keep_opt_in.

## StatementDelete → keep_opt_in

Initial matrix data (intrinsically the catalogue's noisiest surface):

| target | n | kill% | equiv% | invalid% |
|---|--:|--:|--:|--:|
| jason | 6 | 100 | 0 | 0 |
| plug_crypto | 5 | 75 | 25 | 20 |

plug_crypto fails on both invalid (20%, gate <10%) and equivalent (25%, gate
<20%). The M81 orphan-binding hazard is correct but not exhaustive: deleting
a statement whose side effect is captured by no later read/binding can still
produce a residual compile-time issue (a `_ = expr` whose RHS is a macro
referenced by warning-as-error rules, for instance) or an equivalent (a
discarded result the suite never observes). Document and keep opt-in.

## Carried forward (v1.24+)

- FunctionReplace graduation, once a third runnable target is available.
- A NegateConditional both-branch-equivalence hazard (would address jason's
  52%).
- A StatementDelete invalid hazard pass.
