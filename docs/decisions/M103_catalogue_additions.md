# M103 — Data-gated catalogue additions (FunctionReplace allowlist)

**Date:** 2026-06-02

Decision: **no additions shipped.** v1.28's catalogue track measured four
strong-semantic, closed-allowlist FunctionReplace pair-candidates; they are
invalid-safe but showed no kill-signal on the available matrix targets, so —
consistent with the project's data-gated discipline (M60/M88/M93/M95 all
declined to graduate on insufficient evidence) — they are held out of the
default-on surface rather than shipped on thin data.

This is a real data-gated outcome, not a punt: the candidates were implemented,
matrix-measured, and the measurement (not a structural argument) drove the
decision. They remain documented candidates for a future cycle with targets
that actually exercise them.

## Candidates measured (all same module + arity)

| pair | rationale | invalid risk |
|---|---|---|
| `Enum.sort/1` ↔ `Enum.reverse/1` | reorders the result; order-asserting tests kill it, order-agnostic tests leave it surviving (a genuine gap) | 0 — both `Enum`/1 |
| `Enum.take_while/2` ↔ `Enum.drop_while/2` | predicate-driven mirror of the graduated `take`↔`drop` | 0 — both `Enum`/2 |
| `String.upcase/1,2` ↔ `String.downcase/1,2` | case flip; case-sensitive assertions kill it | 0 — both `String`/1,2 |
| `Map.put/3` ↔ `Map.put_new/3` | overwrite vs only-if-absent — differs whenever the key is already present | 0 — both `Map`/3 |

**Invalid-safety is structural.** Every replacement is a real function in the
same module with the same arity (verified), so the swap always produces a
compilable call — the FunctionReplace closed-allowlist invariant that made it
graduate. The only outcome class a new pair can add is *equivalent survivors*
(a swap the suite can't distinguish), which is signal (an untested
distinction), not noise that corrupts the score.

## Matrix measurement

FunctionReplace as a whole (existing + the four candidate pairs),
`--mutators function_replace`, via the M97 sharding harness:

| target | n (M103) | n (M97 baseline) | new candidates | killed | equiv% | invalid% |
|---|--:|--:|--:|--:|--:|--:|
| jason | 2 | 0 | **2** | 0 | 100.0 | 0.0 |
| bandit | 9 | 9 | **0** | 8 | 11.1 | 0.0 |

The candidate pairs added **2** candidates total across both targets (both on
jason), and both were **equivalent** (survived). bandit — the richest measured
FunctionReplace target — added **zero** new candidates (it doesn't call the
candidate functions at the allowlisted resolution). Invalid rate stayed **0%**
(the structural invalid-safety holds), but there is **no kill-signal evidence**
on the available targets.

## Why no-add

- **Invalid-safety is confirmed** (0% — every candidate is a real
  same-module/same-arity function), so they would never *break* a run.
- **But they go into a default-on surface.** A FunctionReplace pair that is
  mostly-equivalent ships *equivalent survivors* to every user by default,
  which depresses the headline mutation score with mutants they can't kill —
  exactly what the opt-in tier exists to prevent. FunctionReplace has no
  per-pair opt-in tier; adding a pair = shipping it default-on.
- **The data is insufficient to clear the bar.** The project graduates to
  default-on only on demonstrated low-equiv/high-kill across ≥3 targets
  (M62 gate; M97 met it for the existing pairs). The candidates here show
  2/2 equivalent on the one target that exercised them and nothing on the
  others — the opposite of graduation evidence.

This matches M60/M88/M93/M95: when the matrix data doesn't justify a default-on
flip, the disciplined outcome is to **not flip**, not to ship on a structural
hunch.

## Decision

**Hold all four candidate pairs** (`Enum.sort`↔`reverse`,
`Enum.take_while`↔`drop_while`, `String.upcase`↔`downcase`, `Map.put`↔`put_new`)
out of the default-on FunctionReplace allowlist. They are recorded in a code
comment in `Mut.Mutator.FunctionReplace` as measured-but-held candidates.
A future cycle can revisit them with matrix targets that exercise them (e.g. a
case-sensitive HTTP/header library for upcase/downcase, an order-sensitive
formatter for sort/reverse) and graduate per the M62 gate if they clear.

The FunctionReplace default-on allowlist is **unchanged** from v1.27/M97 —
demo_app + Decimal default plans byte-identical (golden gates green).

## Out of scope

- Cross-module pairs (e.g. `Enum.count`↔`Kernel.length`) — the closed-allowlist
  invariant is same-module/same-arity; cross-module swaps risk arity/semantics
  drift.
- Arity-changing "pairs" (`Map.put/3`↔`Map.delete/2`) — would produce an
  invalid call.
- Return-value replacement / call deletion — high false-positive, deferred
  indefinitely (Explicitly NOT v1.28).
