# M75 — operator + pattern-shape graduation matrix (v1.21)

**Date:** 2026-05-26

Decision: **all four opt-in surfaces stay `keep_opt_in`.** The M72/M73
hardening made them clean (0% invalid across the matrix), but the kill /
equivalent data under the M62 gate (kill ≥60%, equivalent <20% with a ≤2pp
single-target tolerance, invalid <10%, on **every** matrix target) does not
clear any surface for default-on graduation this cycle.

## Matrix (coverage_with_static_fallback; equivalent = covered-survivors)

| target | mutator | n | kill% | equiv% | invalid% |
|---|---|--:|--:|--:|--:|
| jason | ConcatOperator | 3 | 33.3 | 66.7 | 0 |
| plug | ConcatOperator | 13 | 100 | 0 | 0 |
| decimal | ConcatOperator | 10 | 90 | 10 | 0 |
| jason | Membership | 1 | 0 | 100 | 0 |
| plug | Membership | 8 | 100 | 0 | 0 (1 err) |
| plug_crypto | BitwiseOperator | 1 | 0 | 100 | 0 |
| plug | Pin | 14 | 100 | 0 | 0 |

## Per-surface verdicts

- **ConcatOperator → keep_opt_in.** Clean and productive on list/algebraic
  code (plug 100% kill / 0% equiv; decimal 90% / 10%), but **fails on jason**:
  its only `++` sites are in `codegen.ex` (compile-time code generators), where
  the two survivors are covered → 67% equivalent, 33% kill. The M72 direction
  drop (`--`→`++` removed) eliminated the invalid noise (0% across all), but the
  codegen-heavy equivalence on jason blocks graduation.
- **BitwiseOperator → keep_opt_in.** Input-dependent pseudo-equivalents remain
  (plug_crypto's lone survivor is one); too few sites + 100% equiv on the one
  target with data.
- **Membership → keep_opt_in.** Strong on plug (8/8 killed) but jason's single
  site is a covered survivor (100% equiv) and plug shows one runtime error;
  mixed and thin.
- **Pin → keep_opt_in (leading candidate).** The standout: **plug 14/14 killed,
  0% equivalent, 0% invalid** after the M75 map-key hazard rule (below). But
  plug is the *only* matrix target with unpinnable pins (jason's lone pin was a
  map key → skipped; decimal/plug_crypto have none), so there is not yet
  multi-target evidence to satisfy the gate's "every target" requirement. Pin
  is the surface most likely to graduate once more pin-bearing targets
  (ecto/phoenix/genserver-heavy code) are measured.

## Engine hardening landed during M75

A real Pin hazard surfaced and was fixed (`Mut.AstWalk.pin_candidates`):
**map-key pins (`%{^k => v}`) are excluded** — unpinning to `%{k => v}` is a
compile error (pattern map keys must be literals or pinned). This was a ~30%
invalid rate on real code (plug `conn/query.ex`, csrf; jason `encode.ex`);
after the rule, Pin invalid is **0%**. All other pin positions (case/with/fn
heads, map *values*, `=` matches) unpin cleanly.

## Additive-only

All surfaces remain opt-in; the default plan is unchanged (no graduation), so
existing stable IDs are untouched — confirmed by golden_oracle +
golden_instrument (demo_app + Decimal default plans byte-identical).

## Carried forward

- Pin graduation, once measured on more pin-bearing targets (the gate needs
  multi-target evidence; plug alone is perfect but insufficient).
- ConcatOperator: a codegen-context exclusion could lift jason's equivalence
  and make it graduation-eligible.
