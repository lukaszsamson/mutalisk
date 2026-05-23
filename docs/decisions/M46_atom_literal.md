# M46 — AtomLiteral default policy: default_on (flip bundled with v1.16 env-walker default)

**Date:** 2026-05-23
**Decision:** `default_on` — AtomLiteral clears every M25/M41 threshold on
the execution corpus. Because it targets `:env_walker` (opt-in today),
the actual default flip is bundled with the v1.16 env-walker
default-enablement work; M46 records the decision and the supporting
data.

## Thresholds (M25/M41)

kill ≥ 60% · equivalent < 20% · invalid < 10%

**Decision rule (M46):** a `default_on` flip affects every user, so it
requires clearing the thresholds on **every meaningful-sample target**,
not just the count-weighted corpus aggregate — a single large clean
target (plug, 1390 mutants) otherwise masks a noisy codebase class.
Decimal (fixed-point math; many non-behavioural data/error-string
literals) is the consistent low outlier across the literals. AtomLiteral
is the only literal that clears the per-target bar.

## Execution data (post M46 span fix, `mix` worker, c=4)

| Target | mutants | killed | survived | invalid | kill% |
|---|---:|---:|---:|---:|---:|
| plug_crypto v2.1.1 | 6 | 4 | 2 | 0 | 66.7 |
| Decimal | 70 | 64 | 6 | 0 | 91.4 |
| plug v1.19.1 | 59 | 56 | 3 | 0 | 94.9 |

Per-target kill: **66.7 / 91.4 / 94.9 — all ≥ 60%.** Invalid 0% on every
target. Survivors are <9% on the two large samples (Decimal 70, plug 59);
plug_crypto's 33% (2/6) is below statistical relevance at n=6.

## Rationale

The closed allowlist (`:ok↔:error`, `:lt/:gt/:eq` rotations) targets the
two atom conventions a well-written suite checks (result tags and
comparison results), which is why kill is high and invalid is zero
(swaps are always valid atoms). The "never synthesize a new atom" rule
keeps the equivalent surface tiny. This is the only v1.15 literal that
clears `default_on`.

Since it is the *only* one, the `--enable literal` preset is **deferred**
(the rule requires ≥2 default_on candidates). See
[[M46_collection_empty]], [[M46_string_literal_table]],
[[M46_nil_literal]], [[M46_float_literal]].
