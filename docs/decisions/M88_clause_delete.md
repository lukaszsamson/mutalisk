# M88 — ClauseDelete graduation re-eval (v1.24)

**Date:** 2026-05-28

Decision: **ClauseDelete stays `keep_opt_in`** under the M62 gate. The
hazard discipline (M87 collector-side filtering of last-clause /
`true ->` cond / single-`else` with) cleanly resolved the invalid class
to **0% on every matrix target**, but the equivalent rate fails on plug.

## Matrix (coverage_with_static_fallback, `--concurrency 1`)

| target | n | killed | survived | cov-surv | kill% | equiv% | invalid% | err |
|---|--:|--:|--:|--:|--:|--:|--:|--:|
| jason | 45 | 32 | 8 | 8 | 80.0 | 20.0 | 0.0 | 5 |
| plug | 175 | 120 | 44 | 44 | 73.2 | 26.8 | 0.0 | 11 |
| decimal | 58 | 47 | 10 | 10 | 82.5 | 17.5 | 0.0 | 1 |

Gate: kill ≥60% ✓ everywhere (range 73.2–82.5%). Invalid <10% ✓ — actually
**0% everywhere**, a strong result for the catalogue's intrinsically noisiest
structural surface; the M87 hazards (last-clause, `true ->`, with-`else`-only
with ≥2 else) are doing their job. Equivalent <20% with the ≤2pp single-
target tolerance: jason 20.0% sits at the boundary (within tolerance);
**plug 26.8% fails by 4.8pp beyond the tolerance** (the deciding miss);
decimal 17.5% clears.

## Why the equivalence on plug

ClauseDelete on a `case`/`cond` where a clause's pattern is rarely exercised
by the test suite produces a covered-but-equivalent-to-the-suite mutant —
deleting a clause that the tests don't hit doesn't change observable
behaviour. This is the structural deletion analog of M83's
NegateConditional dead-branch equivalence: a graduation hazard rather than
a quality defect.

## Opportunistic re-eval (per the plan's "M88 only graduates them if they
happen to clear")

- **NegateConditional, StatementDelete**: M86 was redirected (M85 spike's
  AST-shape verdict; see `docs/spikes/M85_fallback_share.md`), so the
  routing characteristics that M88's opportunistic re-eval was scoped
  around are unchanged. No new data collected for them this cycle;
  decisions stand from M83.
- **FunctionReplace third target**: env blockers from M82 (credo regex
  incompat on Elixir 1.19, ecto baseline failures, req ezstd, small
  targets with zero allowlisted call sites) are unchanged; no new path
  cleared this cycle.

## Carried forward (v1.25+)

- ClauseDelete equiv reduction (e.g. pattern-rarity hazard analogous to
  M80's dead-branch no-else): the surface is clean enough that a
  modest equiv-shaving pass would likely clear the gate.
- The recurring "needs breadth" gates (FunctionReplace + Pin-style
  multi-target evidence) move to v1.25 alongside the incremental
  cross-run history bet that M86 (redirected) seeded with
  `bench/cross_run.exs`.

## Non-moved IDs invariant

The M86 invariant ("non-moved mutator stable IDs byte-identical") is
trivially preserved this cycle because M86 was redirected — no mutators
moved engines, so no IDs migrated. demo_app + Decimal default plans
stay byte-identical (golden gates confirm).
