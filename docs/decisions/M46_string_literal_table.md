# M46 — StringLiteral expand_table default policy: keep_opt_in

**Date:** 2026-05-23
**Decision:** `keep_opt_in` (unchanged from M41's plan-level call, now
confirmed at execution). Kill rate is highly target-dependent and the
prepend-space row is equivalent-heavy.

## Execution data (post M46 span fix, `mix` worker, c=4)

| Target | mutants | killed | survived | invalid | kill% |
|---|---:|---:|---:|---:|---:|
| plug_crypto v2.1.1 | 21 | 18 | 3 | 0 | 85.7 |
| Decimal | 57 | 15 | 42 | 0 | **26.3** |
| phoenix_html v4.3.0 | 66 | 60 | 6 | 0 | 90.9 |
| plug v1.19.1 | 351 | 304 | 45 | 0 | 87.1 |

(rows = strings × 3 table entries. Aggregate kill 80.5%, survivors 19.4%
— but **Decimal is 26.3%**, failing the per-target-minimum rule; see
[[M46_atom_literal]].)

## The M46 span fix

This is the milestone's headline finding. StringLiteral (and the other
env-walker scalar literals) had a **broken `source_span`** since M40/M44:
the span covered ~1 character (the opening `"`), not the whole literal,
because the parser's `literal_encoder` drops `:token` for strings and the
walker fell back to a 1-char span. M41 only validated stable-ID
*distinctness*, never execution, so it went unnoticed. At execution the
splice produced `"…"` + leftover → **100% CompileError**.

M46 fixed `Mut.EnvWalker.literal_span` to compute the true end by
scanning the source (`:token` length for numbers, `:delimiter` scan for
strings/quoted atoms, value length for bare atoms/`nil`). This **churns
the stable IDs** of StringLiteral / AtomLiteral / NilLiteral (the span is
a stable-id input) — an accepted one-time correctness migration, since
those mutators never produced a valid mutant before. FloatLiteral
(`:token`) and CollectionEmpty (`:closing`) were already correct and did
not churn; non-literal and body-literal (AstWalk) mutants are untouched.

## Rationale for keep_opt_in

- kill swings 85.7% → 26.3% across two targets — not a stable
  default-on signal.
- The `→ "x"` and especially `→ " " <> s` (prepend-space) rows are
  frequently equivalent (leading whitespace rarely changes asserted
  behavior); Decimal's 42 survivors are dominated by them.
- invalid is now 0% (post-fix), so the mutator is *usable* opt-in.

Kept opt-in. A future trim (drop the prepend-space row) could raise the
effective kill rate; deferred to v1.16 alongside any env-walker literal
schema migration. See [[M46_atom_literal]].
