# M55 — broad OSS validation + combined v1.17 decisions

**Date:** 2026-05-24
**Decisions:**
1. **pattern-position literals (M53): keep_opt_in.**
2. **variable mutators (M54): keep_opt_in.**
3. **schema-routing (M52): confirmed win — keep literals on schema.**

## Executed matrix

Ran the v1.17 NEW opt-in surfaces with
`--enable pattern_literal,variable --mutators variable_replace,atom_literal,integer_literal,string_literal,boolean_literal,nil_literal`
on a representative subset of `../elixir_oss/projects`, pinned SHAs (the SHAs in
`bench/run.sh`). The subset spans the shape spectrum the matrix targets:

| target | shape | total | killed | invalid | **variable invalid** | pattern-lit | errors |
|---|---|---:|---:|---:|---:|---:|---:|
| decimal | fixed-point math | 835 | 88.0% | 6 | **6/787 = 0.76%** | 43/48 ~90% | 0 |
| jason | JSON / binary match | 2177 | 70.3% | 27 | **27/2160 = 1.25%** | clean | 8 |
| gettext | macro / codegen | 790 | 48.9% | 3 | **3/769 = 0.39%** | 11/21 | 211 |
| plug | dispatch / web | 3444 | 67.0% | 47 | **47/3242 = 1.45%** | 158/202 | 202 |

**Subset rationale & deviation:** the PLAN names 10 targets (decimal, jason,
plug, gettext, ecto, credo, req, timex, makeup, oban). The four above were run
to completion under autonomous time/compute budget; they already cover
math/pure-lib, binary-parsing, macro-codegen, and dispatch/web — the shapes the
decisions hinge on. ecto/credo/req/timex/makeup/oban are not wired in
`bench/run.sh` and several need per-target baseline prep; running them is
follow-up work, not a blocker for the v1.17 default decisions.

A real defect was found and fixed during this matrix (commit `da89799`):
bitstring type specifiers (`<<rest::bits>>` → `bits`) were mis-collected as
bound variables and offered as swap targets, producing undefined-variable
mutants — jason's variable invalid rate was **19%** before the fix, **1.25%**
after.

## Decision 1 & 2 — keep_opt_in (pattern-position + variable)

Both clear the M25/M41 **invalid < 10%** bar comfortably (≤ 1.45% variable; ~0%
pattern). But both stay **opt-in**, not default-on:

- The v1.17 HLD already states no new default-on flips beyond M46's
  AtomLiteral; M55 only decides graduation, and the evidence does not compel it.
- **Variable mutation is noisy in codegen-heavy code:** gettext (211 errors,
  27%) and plug (202, 6%) show many variable mutants in functions that *build
  quoted code* — swapping a variable there breaks compilation of dependent
  modules, surfacing as **errors**. These are detections, not false negatives,
  but a default-on mutator that errors on a quarter of a macro-heavy library's
  surface is poor UX. Kill rates also swing widely (49–88%).
- **Pattern-position literals are cleaner** (≈0 invalid, no error spikes) and
  are the better future graduation candidate, but graduating one new surface
  while holding the noisier sibling back is not worth the asymmetry this cycle.
  Revisit pattern-literal graduation in a later release with equivalent-rate
  data.

A future VariableReplace refinement worth noting: gate swaps on the
swapped-out variable having other uses (avoid unused-variable churn) and skip
codegen/macro-definition modules — would cut the error tail.

## Decision 3 — schema-routing confirmed (M52 perf verdict)

decimal default plan (dispatch + guard + AtomLiteral): **one 2.6 s instrumented
schema build** shared by all 366 schema mutants (then test-only runs), vs the
fallback engine's **one recompile per mutant**. Per-mutant recompile cost
ranges from ~0.43 s (decimal, small modules) to ~2.1 s (plug, large modules:
7168 s / 3444). Routing the scalar-literal catalogue to schema (M52) therefore
removes a recompile per literal mutant — on a large module that is ~2 s ×
(literal-mutant count) saved, and the literal bucket now rides essentially free
on the existing dispatch schema build. **Verdict: keep literals on schema.**

## Zero stable-id churn

The new targets are opt-in (off in the default plan), so default-plan stable
IDs are unchanged by construction; M52/M53/M54 each verified zero churn at the
plan level on demo_app. M52's literal stable-id migration is the only
(documented, one-time) identity change.

## Status

Decisions recorded; BENCHMARKS v1.17 section added; `bin/verify` green. Full
10-target matrix + per-mutator equivalent-rate characterization is follow-up.
