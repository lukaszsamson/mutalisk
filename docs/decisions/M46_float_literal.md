# M46 — FloatLiteral default policy: keep_opt_in (insufficient evidence)

**Date:** 2026-05-23
**Decision:** `keep_opt_in`. The corpus contains too few body-context
float literals to validate a default-on flip.

## Execution data (post M46 span fix, `mix` worker, c=4)

| Target | mutants | killed | survived | invalid | kill% | inv% |
|---|---:|---:|---:|---:|---:|---:|
| Decimal | 1 | 0 | 1 | 0 | 0.0 | 0.0 |

(demo_app's `literals_sample.ex` is not compiled by the oracle build;
plug_crypto and Decimal together yield a single body float literal —
Decimal is a fixed-point library and stores no float constants.)

## Rationale

n = 1 is not a basis for a default-on decision. invalid is 0% (FloatLiteral
always carried a correct `:token`-based span, so it was unaffected by the
M46 span fix and did not churn). The single Decimal float survived, but
one data point says nothing about the threshold.

Kept opt-in pending a corpus with meaningful float-constant density
(numeric/graphics/scientific libraries) in a later validation cycle. See
[[M46_atom_literal]].
