# M46 — CollectionEmpty default policy: keep_opt_in

**Date:** 2026-05-23
**Decision:** `keep_opt_in`. Kill rate clears 60% but the survivor
(equivalent-upper-bound) rate exceeds the 20% bar on Decimal, and it is
the higher-noise mutator of the pair by design.

## Execution data (post M46 span fix, `mix` worker, c=4)

| Target | mutants | killed | survived | error | invalid | kill% |
|---|---:|---:|---:|---:|---:|---:|
| demo_app | 1 | 1 | 0 | 0 | 0 | 100.0 |
| plug_crypto v2.1.1 | 13 | 12 | 0 | 1 | 0 | 100.0 |
| Decimal | 36 | 25 | 11 | 0 | 0 | 69.4 |
| phoenix_html v4.3.0 | 36 | 36 | 0 | 0 | 0 | 100.0 |
| plug v1.19.1 | 196 | 165 | 10 | 18 | 3 | 94.3 |

Corpus aggregate: 239 killed / 21 survived / 19 error / 3 invalid →
**91.9% kill**, survivors **7.4%**, invalid **1.1%**. On the aggregate,
all thresholds pass — but **Decimal alone is 30.6% survivors**.

## Rationale (keep_opt_in despite the aggregate passing)

- invalid is ~1% (3/282, all on plug) — the `:closing`-based span (M45)
  is correct and the literal_encoder discrimination keeps it off
  keyword-list args and `do:` blocks; well under the 10% bar.
- The aggregate clears the thresholds, but **Decimal alone shows 30.6%
  survivors** — emptying a list/tuple the tests don't behaviourally
  observe (internal accumulators, debug data) is frequently equivalent.
  This is exactly the higher-noise behaviour the v1.15 HLD flagged for
  CollectionEmpty.
- Under the per-target-minimum rule ([[M46_atom_literal]]), a default-on
  mutator should not have a representative target at ~30% survival; the
  count-weighted aggregate (dominated by plug's 196 mutants) masks it.
  Four of five targets are clean, but the one non-trivial fixed-point
  library is not.

Kept opt-in on this per-target-noise guard. Revisit in v1.16 once
maps/n-tuples land (deferred from M45) and survivor classification can
separate equivalent from weakly-tested-but-real. Only [[M46_atom_literal]]
clears `default_on`, so the `--enable literal` preset is **deferred**
(the rule requires ≥2 default_on candidates).
