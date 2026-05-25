# M60 — surface graduation: graduate NOTHING (data-gated)

**Date:** 2026-05-25
**Decision:** No v1.17 surface graduates to default-on. Pattern-position
literals and the refined `VariableReplace` both **stay opt-in**. The
default-on tier is unchanged. This is the data-gated outcome the v1.18 plan
explicitly permits ("ship only what the data clears; neither flips on
assertion").

## Gate

M25/M41 per-target-minimum rule — a surface graduates only if it clears, on
**every meaningful-sample target**: kill ≥ 60%, **equivalent < 20%**,
invalid < 10%. The M59 matrix supplies the equivalent-rate (covered-survivor
heuristic, an over-estimate).

## Equivalent-rate vs the 20% bar (M59, coverage targets)

| surface | decimal | jason | ecto | plug | clears every target? |
|---|---:|---:|---:|---:|---|
| VariableReplace (M57-refined) | 9.0% | 22.6% | 39.2% | 33.7% | **No** (3/4 fail) |
| pattern AtomLiteral | 16.7% | — | 25.0% | 20.6% | **No** (ecto, plug) |
| pattern IntegerLiteral | 5.6% | 0% | 21.1% | 15.6% | **No** (ecto, marginal) |
| pattern NilLiteral | — | — | 29.6% | 33.3% | **No** |
| pattern BooleanLiteral | — | 33%* | 27.3% | 14.3% | **No** (ecto) |
| pattern StringLiteral | 0% | 50%* | 0% | 13.3% | borderline (jason n=2) |
| VariableToLiteral | 1.6% | 39.7% | 37.5% | 48.2% | **No** |

(\* tiny samples. makeup omitted — weak suite, 35.9% kill, inflates equivalent.)

## Call

- **VariableReplace: keep_opt_in.** Despite M57 cutting its *error* tail
  sharply, its *equivalent* rate is 22–39% on jason/ecto/plug. Variable swaps
  frequently produce behaviour the suite cannot distinguish (intermediate
  values, data-shuffling). Far over the bar; not a default.
- **Pattern-position literals: keep_opt_in.** No literal mutator clears < 20%
  on every target. **IntegerLiteral-in-pattern is the closest** (clears
  decimal/jason/plug; fails ecto only, marginally at 21.1%) — the prime future
  candidate, but the strict per-target rule + the heuristic being an
  over-estimate (true equivalent is lower, but unproven) argue for waiting on
  better equivalent-detection rather than graduating on a marginal miss.
- **VariableToLiteral: keep_opt_in** (also explicitly `--mutators`-only).

## Effect

`Mut.Mutator.Defaults.default_on/0` is **unchanged** (dispatch + guard +
AtomLiteral, since M48). The default plan is byte-identical — zero stable-id
change (the "additive-only" acceptance holds trivially: nothing was added).
`bin/verify` green.

*Future:* revisit IntegerLiteral-in-pattern graduation once equivalent
detection is sharper (the covered-survivor heuristic over-counts weak
assertions); see the v1.18 horizon "further surface graduation".
