# Changelog

All notable changes to Mutalisk are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## v1.7 (M19, 2026-05-06)

### Added
- **`--worker-type persistent` (opt-in).** A new worker model that
  keeps one ExUnit BEAM alive per sandbox and flips
  `:persistent_term` between mutants instead of spawning a fresh
  `mix test` per mutant. Schema mutants only; fallback continues to
  use the v1.6 mix-spawn path.
- `Mut.Worker.Persistent` host GenServer + `Mut.Worker.PersistentRunner`
  in-BEAM runner. ExUnit.Server state is snapshotted at boot and
  restored before every run so the same loaded test modules
  re-execute deterministically.
- `Mut.Worker.PersistentRunner.Reset` collects per-leak-vector
  snapshot/reset helpers (Application env, ETS tables, registered
  processes, persistent_term, ExUnit OnExitHandler) used between
  iterations. Reset uses lazy baselines captured AFTER the first
  ExUnit.run so the diff treats ExUnit's own infra as part of the
  baseline.
- ExUnit `only_test_ids` file filter so the persistent worker runs
  only the selected test files per mutant (matching the v1.6
  selection pipeline).
- Per-sandbox parallel persistent workers via M17's
  `Mut.SandboxQueue`.
- Crash recovery: a worker BEAM crash routes the offending mutant
  AND every subsequent mutant on the same sandbox to the mix-spawn
  worker. The persistent server is `GenServer.start` (not linked)
  so its crash does not propagate to the host's
  `Task.async_stream` worker.

### Changed
- **`mix.exs` requires Elixir `>= 1.18.0`.** Pre-1.18 users stay
  on v1.6.x. The persistent runner depends on internal ExUnit
  semantics (`ExUnit.OnExitHandler` ETS, ExUnit.Server state shape)
  stable from 1.18 onward.
- `bench/run.sh` accepts `--worker-type mix|persistent`.

### Known limitations (v1.7.0)
- **Default stays `--worker-type mix`.** Persistent worker is opt-in
  for the first v1.7 release.
- **Spurious kills observed on plug_crypto-class targets** that
  exercise crypto/setup_all state across tests. demo_app and
  Decimal-class targets are byte-identical between worker types;
  plug_crypto persistent reports more "killed" outcomes than mix
  due to setup_all state leakage that the lazy-baseline reset
  doesn't fully cover. v1.7.x will sharpen the reset hooks. **Use
  `--worker-type mix` for plug_crypto-style projects until then.**
- **In-process fallback recompile is deferred.** Fallback mutants
  always route to the mix-spawn worker, preserving M17's
  "0 invalid Decimal fallback" baseline regardless of worker type.
- **`e2e_persistent` verify layer is defined but not enabled.** The
  `mut.e2e` wrapper hangs when chained with the persistent worker;
  diagnosis pending. Standalone `mix mut --worker-type persistent`
  runs cleanly.
- **No automatic worker-restart after crash.** Per-sandbox fallback
  to mix happens after the first crash. V17's full restart-then-
  fallback design ships when the spurious-kill issue above is
  resolved.

### Internal
- `lib/mut/worker/persistent.ex` (host).
- `lib/mut/worker/persistent_runner.ex` (in-BEAM).
- `lib/mut/worker/persistent_runner/reset.ex` (leak-vector helpers).
- `bin/verify` defines `e2e_persistent` (disabled).

## v1.6 (M17, 2026-05-05)

### Changed
- **`mix mut` defaults to parallel execution.** The default
  `--concurrency` is now `min(System.schedulers_online(), 4)`, capped
  at 4. Use `--concurrency 1` for v1.5 sequential behaviour.
  Outcomes are byte-identical across `c=1/2/4/8` on demo_app,
  plug_crypto, and Decimal (M17 validation matrix).
- Decimal-class projects (e.g. `lukaszsamson/decimal@mutalisk-bench`)
  now complete comfortably under 30 minutes at the new default. See
  `BENCHMARKS.md` "Concurrency speedup curve (M17)" for full numbers.

### Added
- Reports include concurrency metadata.
  - Terminal summary prints a `Concurrency: N workers` line near
    the bottom (with `(sequential)` or `(capped at N
    schedulers_online)` suffix when applicable).
  - Stryker JSON gains a top-level `mutalisk.concurrency` block:
    `{ "configured", "effective", "schedulers_online" }`.
- Reports distinguish fallback recompile failures by category.
  - `:compile_error` — patched Elixir source did not compile.
  - `:dep_path_error` — required module not loadable from `-pa`.
  - `:unknown` — non-zero exit without a known signature.
  - Terminal summary surfaces a "recompile errors" sub-block under
    Fallback when total > 0.
  - Stryker JSON gains `mutalisk.recompile_categories` counts.
- New `Mut.SandboxQueue` (PROMPT_16, hardened in M17) audited and
  regression-tested under 32-task / 8-sandbox concurrent stress.
- New `Mut.LastKiller` concurrent stress test plus a p99 latency
  regression bar (sub-millisecond record_kill).

### Fixed
- M17 sandbox audit captured no behavioural fixes (the existing
  sandbox lifecycle is concurrency-safe), but the audit's
  regression test guards against future regressions.

### Internal
- `%Mut.Metrics.Snapshot{}` carries `concurrency` and
  `recompile_categories` fields.
- `Mut.Worker.Result{}` carries `recompile_category`.
- `Mut.Recompile.categorize/1` is the public classifier.

## v1.5 (M15 + M16)

- Coverage-aware test selection (`--selection coverage`,
  `--selection coverage_with_static_fallback`).
- Phase timing metrics in reports.
- See `BENCHMARKS.md` v1.5 section for outcomes.

## v1 (M0–M14)

- Schema-engine + fallback-engine mutation execution.
- Stryker-compatible JSON reporter.
- See `BENCHMARKS.md` v1 reference run.
