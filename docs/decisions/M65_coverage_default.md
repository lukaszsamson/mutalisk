# M65 — flip `--selection` default to `coverage_with_static_fallback`

**Date:** 2026-05-25
**Decision:** Flip the default `--selection` from `static` to
`coverage_with_static_fallback` — the v1.5-planned default, now that M64 makes
coverage crash-safe (per-file degrade). `--selection static` stays the
documented, fully-portable escape hatch. Bare `coverage` is never the default.

## Why now (vs v1.18's M61 no-flip)

M61 kept static because coverage *aborted* on 3/8 targets. M64 fixed that (a
failed test file degrades to static, run continues). With aborts gone, the
remaining gate was the M65 acceptance: **coverage must not regress kill
counts** (selection narrows test *work*, not *outcomes*).

## Kill-count parity (validated)

decimal, default plan, same mutant set, static vs coverage:

| run | killed | score |
|---|---:|---:|
| static | 385 | 80.9% |
| coverage (run 1) | 384 | 80.7% |
| coverage (run 2) | **385** | **80.9%** |

The run-1 single-mutant difference (`decimal.ex:432 :gt→:eq`) was **test
flakiness**, not a selection gap: run 2 killed it, matching static exactly. The
flaky kill is a property of decimal's suite (the same mutant can flip under
static too), independent of selection. **Selection preserves outcomes.**

gettext (M64 degrade target): completes under coverage (degrades `backend_test`)
— no abort, results produced.

## Wall-clock / fanout

Coverage selects only covering tests per mutant (lower fanout) but adds a
one-time collection pass. On **fast-suite** targets the collection overhead
roughly offsets the per-mutant savings (decimal: static 240 s vs coverage 247 s
— ~neutral; collection 5.9 s, 33 mutants static-fallback). The win is on
**slow-suite** targets, where cutting tests-per-mutant dominates the fixed
collection cost. Either way correctness is preserved and crashes degrade
gracefully — so coverage is the better *default*, with `static` available when
collection overhead isn't worth it.

## Effect

- Default `--selection` = `coverage_with_static_fallback`. `--selection static`
  unchanged and still selected per run in the report. Bare `coverage` opt-in.
- `bin/verify` green (e2e_mut now runs demo_app under coverage by default).
- No mutator/stable-id change.

*Caveat:* coverage adds a collection pass; on tiny/fast suites `static` may be
faster. Coverage caching / cross-run history remain v2.
