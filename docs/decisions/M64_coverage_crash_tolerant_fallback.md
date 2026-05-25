# M64 — per-file crash-tolerant static fallback in the coverage runner

**Date:** 2026-05-25
**Goal:** make `coverage_with_static_fallback` degrade **per test file** instead
of aborting the whole run, closing the three M61 coverage failure modes
(gettext compile-in-test, credo timeout, timex hot-codeload crash).

## Change

`Mut.Coverage.Runner.collect_files/4` used `Enum.reduce_while` that **halted on
the first per-file `{:error, …}`**, failing the entire run. It now uses a plain
`reduce`: a file whose per-file coverage collection fails (exception, timeout,
exit≠0, BEAM crash → all surface as `{:error, reason}`) is **recorded as
degraded** and the run continues. The mode is irrelevant — every per-file error
takes the same degrade branch.

Degraded files are stored on `CoverageOracle.degraded_test_files`
(`[{path, reason}]`).

### No false survivors

A degraded file collected no coverage, so the mutants it exercises would lack
its contribution. `Mut.TestSelection.Coverage.select/5` now **unions the
degraded files' static coverage** into each mutant's selection
(`degraded_cover/3`, mirroring `static_tests/3`'s evidence gate over the
degraded set): a degraded file still runs for the mutants it *statically*
covers, so degradation can't cause a mutant to escape a test that would kill it.
Mutants unrelated to a degraded file are unaffected.

### Surfaced

The run prints, e.g.:

```
Coverage: 1 test file(s) degraded to static selection (per-file collection
failed; their tests still run for the mutants they statically cover):
  - test/gettext/backend_test.exs: coverage_test_failed
```

## Validation

- **gettext** (the M61 exception failer): coverage previously **aborted**; now
  it degrades `backend_test.exs` to static and **completes** (score 48.7%),
  with the notice above. End-to-end proof the mechanism fires.
- **Unit:** `coverage_test.exs` — a degraded file's static coverage is unioned
  into a covered mutant's selection; an unrelated degraded file is not.
- **credo (timeout) / timex (crash):** the same `{:error}` → degrade branch;
  full coverage re-validation across all three is M65's matrix step.
- M59 clean targets collect coverage exactly as before (no degraded files →
  identical selection). `bin/verify` green.

*Out of scope:* bare `coverage` robustness (allowed to fail loudly); elastic
per-file timeouts (the fixed 60 s timeout + pathology→static heuristic suffice);
the default flip (M65).
