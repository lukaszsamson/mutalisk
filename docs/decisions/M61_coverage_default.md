# M61 — coverage-as-default: DO NOT flip (data-gated)

**Date:** 2026-05-25
**Decision:** Keep `--selection static` as the default. Do **not** flip the
default to `coverage_with_static_fallback`. Coverage selection is not robust
enough on real projects to be the default; the M59 matrix is the evidence.
Like M60, this is a data-gated no-flip the v1.18 plan permits ("neither flips
on assertion; both depend on the M59 matrix").

## Gate

M61's acceptance was: "coverage default validated on the matrix; kill counts
match static." Validation requires coverage to *run*. It does not, on a
material fraction of the matrix.

## Coverage collection failed on 3 of 8 targets (M59)

| target | coverage outcome |
|---|---|
| decimal, jason, ecto, plug, makeup | ran |
| **gettext** | FAILED — `backend_test` compiles a Gettext backend at test time; `Kernel.ParallelCompiler` under `:cover` raises "cannot spawn parallel compiler task because the current file is not being compiled/required" |
| **credo** | FAILED — `coverage_test_timeout` (60 s) on `alias_as_test`; `:cover` instrumentation slows credo's already-slow tests past the deadline |
| **timex** | FAILED — tzdata fetches a new release mid-test (network) and the BEAM aborts with a JIT assertion (`Could not resolve all links`) under `:cover` |
| plug | transient `:enoent` spawning `mix` (recovered on retry) — also a robustness smell |

A default that breaks the run on ~3/8 of representative projects is worse UX
than the current static default, which ran on all of them (and on the full M25
corpus historically). So coverage cannot be the default yet.

## Robustness gaps to fix before a future flip

1. **compile-in-test under `:cover`** (gettext) — coverage must tolerate (or
   skip-and-static-fallback for) test files that compile modules at runtime.
2. **slow-test timeout under `:cover`** (credo) — coverage instrumentation
   overhead needs a higher/elastic per-file timeout, or fall back to static
   for files that exceed it.
3. **`:cover` + JIT / dynamic-codeload crashes** (timex/tzdata) — likely needs
   `:cover` disabled for, or graceful-fallback around, modules that hot-load
   code; may be partly out of mutalisk's control (BEAM JIT).

These are coverage-*runner* hardening, distinct from "flip the default" — a
future milestone (v1.18 horizon / v1.19). Until then static is the default and
the only fully-portable mode.

## Effect

- Default `--selection` unchanged (`static`). `coverage_with_static_fallback`
  and `coverage` remain available opt-in (`--selection`), with the documented
  caveat that coverage can fail on compile-in-test / slow / hot-codeload
  suites. Active mode is reported per run (unchanged).
- No code change; `bin/verify` green.

*Out of scope:* the coverage-runner hardening above; bare `coverage` as default;
cross-run history (v2).
