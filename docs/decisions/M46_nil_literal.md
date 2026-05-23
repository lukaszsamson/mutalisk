# M46 — NilLiteral default policy: keep_opt_in

**Date:** 2026-05-23
**Decision:** `keep_opt_in`. The corpus aggregate clears 60%, but Decimal
alone is far below it — fails the per-target-minimum rule (see
[[M46_atom_literal]]).

## Execution data (post M46 span fix, `mix` worker, c=4)

| Target | mutants | killed | survived | invalid | kill% |
|---|---:|---:|---:|---:|---:|
| Decimal | 6 | 1 | 5 | 0 | **16.7** |
| phoenix_html v4.3.0 | 1 | 1 | 0 | 0 | 100.0 |
| plug v1.19.1 | 31 | 31 | 0 | 0 | 100.0 |

Aggregate: 33 killed / 38 = 86.8% — but **Decimal is 16.7%**.

## Rationale

`nil → :__mut_nil__` survives whenever the result flows into a truthiness
check (`if x`, `x || default`) rather than an equality assertion —
`:__mut_nil__` is truthy where `nil` is falsy, so call sites that only
care about truthiness don't notice. Decimal's nils sit in exactly such
positions (16.7% kill), while plug's are mostly compared/returned
directly (100%).

The count-weighted aggregate (86.8%) is dominated by plug's 31 mutants
and masks Decimal's noise. Under the per-target-minimum rule a default-on
mutator must not have a representative target at 16.7% kill, so
NilLiteral stays **opt-in**. invalid 0% post span fix → usable opt-in.
See [[M46_atom_literal]], [[M46_string_literal_table]] (span fix).
