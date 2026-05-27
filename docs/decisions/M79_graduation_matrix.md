# M79 — v1.22 graduation matrix + decisions (FunctionReplace, NegateConditional, Pin re-eval)

**Date:** 2026-05-27

Coverage OSS matrix (equivalent = covered-survivors) of the v1.22 + carried
opt-in surfaces, under the M62 gate (kill ≥60%, equivalent <20% with a ≤2pp
single-target tolerance, invalid <10%, on **every** matrix target).

Decision: **ConcatOperator graduates to default-on**; everything else stays
`keep_opt_in`.

## Matrix

| target | mutator | n | kill% | equiv% | invalid% |
|---|---|--:|--:|--:|--:|
| jason | ConcatOperator | 1 | 100 | 0 | 0 |
| plug | ConcatOperator | 13 | 100 | 0 | 0 |
| decimal | ConcatOperator | 10 | 90 | 10 | 0 |
| plug | FunctionReplace | 13 | 100 | 0 | 0 |
| plug | Pin | 14 | 100 | 0 | 0 |
| plug | Membership | 8 | 100 | 0 | 0 |
| jason | Membership | 1 | 0 | 100 | 0 |
| plug_crypto | BitwiseOperator | 1 | 0 | 100 | 0 |
| jason | NegateConditional | 27 | 48 | 52 | 0 |
| plug | NegateConditional | 189 | 99.3 | 0.7 | 15.3 |
| decimal | NegateConditional | 69 | 74.6 | 25.4 | 0 |
| plug_crypto | NegateConditional | 12 | 50 | 50 | 0 |

(gettext excluded — baseline blocker.)

## Decisions

- **ConcatOperator → GRADUATE (default-on).** Clears the gate on every target
  that exercises it: jason 100% kill / 0% equiv, plug 100% / 0%, decimal 90% /
  10%, **0% invalid everywhere**. The M72 direction-drop (`--`→`++` removed) and
  the M78 codegen-context exclusion (jason 67% → 0% equiv) made it clean.
  Graduation is **additive**: Decimal +10 mutants, 0 existing stable IDs changed
  (PRE 549 → POST 559, verified by `--debug-plan` diff); demo_app has no `++`,
  so its default plan is byte-identical (golden gates green). First new
  default-on graduation since M63.
- **FunctionReplace → keep_opt_in.** Flawless where it fires (plug 13/13 killed,
  0% equiv, 0% invalid) but only plug exercised it — jason/decimal/plug_crypto
  have no allowlisted `Enum`/`List`/`String` paired calls. Single-target, like
  Pin in M75 → the leading graduation candidate, deferred for breadth.
- **NegateConditional → keep_opt_in.** Two disqualifiers, both anticipated:
  high **dead-branch equivalence** (jason 52%, decimal 25%, plug_crypto 50% —
  forcing a branch the code doesn't rely on) and **15.3% invalid on plug**
  (forcing/negating conditions yields compile errors — unreachable clauses,
  unused bindings, type violations under warnings-as-errors). High-yield when it
  kills (plug 99.3%) but too noisy to default-on without an equivalence/dead-
  branch gate (future work).
- **Pin → keep_opt_in (still).** Re-eval did not add pin-bearing targets
  (gettext failed; jason/decimal/plug_crypto have no non-map-key pins). Plug
  remains 14/14 killed, 0% equiv/invalid — still single-target, same blocker as
  M75.
- **BitwiseOperator / Membership → keep_opt_in.** Thin data + jason/plug_crypto
  pseudo-equivalent (100% equiv on their single sites).

## Carried forward

- FunctionReplace + Pin graduation once measured on more targets that exercise
  them (both are clean-but-single-target — the recurring "needs breadth" gate
  failure, not a quality problem).
- A NegateConditional dead-branch / force-invalid gate, if the surface is to
  graduate.
