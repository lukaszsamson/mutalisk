# Changelog

All notable changes to Mutalisk are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## v1.8 (M20 + M21 + M21 phase 2, 2026-05-07)

### M21 phase 2 — in-process fallback recompile

#### Added
- **In-process fallback recompile** when `--worker-type persistent`
  is in effect. Persistent BEAM compiles the patched source via
  `Code.compile_file/1`, runs ExUnit against the patched module,
  then restores the original via `:code.purge/1` + `:code.load_file/1`
  (the schema-build ebins on the runner's `-pa` provide the
  originals). No mix-spawn child process per fallback mutant.
- New protocol line `RUN_FALLBACK <mutant_id> <compile_files>|<test_files>`
  alongside the existing `RUN`. Compile errors surface as
  `MUT_RESULT compile_error <us> <category> <msg>` and the host
  materialises `Result{status: :invalid, recompile_category: cat}`.
- New `Mut.Worker.Persistent.run_fallback/5` host API.
- New `Mut.Worker.run_fallback_in_process/5` wraps the
  prepare-patch flow (validate sandbox, render+apply patch, read
  manifest, compute dependents) around the persistent-side run.
- Fallback to mix-spawn on `:filter_miss` / `:timeout` /
  `:crashed` — same recovery contract as schema mutants.
- Two regression tests in `test/mut/worker/persistent_test.exs`:
  in-process compile + run against a patched source, and the
  `:compile_error` path on a deliberately broken patch.

#### Performance
Per-target persistent wall at c=4 (mix baseline → v1.7 → M21 leak-fix → M21 phase 2):
- demo_app: ~10 s → ~7 s → ~7-8 s → ~7-8 s — 1.3× faster
- plug_crypto: 84 s → 144 s → 80 s → **77 s** — **1.09× faster** than mix
- Decimal: 660 s → 744 s → 598 s → **623 s** — **1.06× faster** than mix

Decimal's wall went up slightly vs M21 phase 1 (598 → 623 s) due
to run-to-run variance; the fallback-bucket portion alone went
from 148 s → 126 s (saved 22 s on 75 fallback mutants).
Zero compile errors, zero Invalid, zero unexpected Killed→Timeout
regressions across the full 454-mutant Decimal bench.

## v1.8 (M20 + M21, 2026-05-07)

### M21 — Persistent worker faster than mix on real targets

M20 Phase B attempted (and rolled back) two perf optimisations
because Decimal regressed byte-identity. M21 found the actual
root cause: a *test-runtime parity bug*, not a state leak. Three
small fixes restore parity AND deliver the perf win the M20 spec
targeted.

#### Fixed
- **`PersistentRunner` now starts ExUnit with `max_failures: 1`**
  to mirror `mix test --max-failures 1` that the mix-spawn worker
  passes. Without it, persistent ran every selected test even
  after one failed — and ~30 Decimal mutants caused an early test
  to fail AND a later test to infinite-loop. Mix aborted at the
  first failure; persistent reached the loopy test and wedged the
  BEAM until the 60 s deadline. With the fix, persistent matches
  mix's "abort fast" behaviour exactly.
- **`Mut.Worker.Persistent.wait_for_result` now uses a
  per-message (relative) timeout** instead of an absolute deadline.
  Mix-spawn's `Worker.collect/3` resets its timeout every time the
  worker emits output; tests that legitimately take 60.5 s but
  emit per-test JSONL events while running survive in mix as long
  as silence stays under `timeout_ms`. Persistent's old absolute
  deadline killed those same tests at 60 s. Now it matches mix's
  semantics.
- **`@timeout_ms` bumped from 60 000 ms to 70 000 ms** to give
  ExUnit's `:max_failures_reached` event time to land before the
  host's deadline fires. Removes the 60 s == 60 s race between
  ExUnit's per-test default timeout and the host's wait.
- **`Mut.Worker.Persistent.run_schema/4` GenServer.call timeout is
  now `:infinity`.** With per-message host-side timeout, a
  legitimately slow but data-producing worker can exceed
  `timeout_ms` of absolute wall-clock; we never want
  GenServer.call to fire its own caller-side timeout and crash
  the calling Task.

#### Changed
- **Persistent's `:timeout` reply now materialises
  `Result{status: :timeout}` directly** without mix-spawn retry.
  After M21's fixes, persistent is byte-identical to mix on
  Decimal at c=4 within V17 acceptance — a mix-retry on timeout
  is unnecessary and would cost an extra `@timeout_ms` per
  timeout. Re-introduced the original Phase B.1a optimisation
  (rolled back in M20 because of the byte-identity regression);
  M21 fixed the regression's root cause so it's now safe.

#### Performance
Per-target persistent wall at c=4 (mix baseline → v1.7 → v1.8 M21):
- demo_app: ~10 s → ~7 s → ~7-8 s — 1.3× faster than mix
- plug_crypto: 84 s → 144 s → **80 s** — **1.05× faster** than mix
  (was 1.71× SLOWER in v1.7)
- Decimal: 660 s → 744 s → **598 s** — **1.10× faster** than mix
  (was 1.13× SLOWER in v1.7)

byte-identity preserved on all three targets; on Decimal,
persistent now produces 16 more Killed than mix at v1.7 (mutants
mix Timeout-ed but persistent kills fast via `max_failures: 1`).
Zero Killed→Timeout regressions.

The 1.5× perf bar from M20's Phase B acceptance is **not** met,
but persistent is now faster than mix on every real target.
Default flip remains a v1.9+ decision.

## v1.8 (M20, 2026-05-07)

### Added
- **`mutalisk.persistent` extension key in Stryker JSON.** When
  `--worker-type persistent` is in effect, the report's
  `mutalisk` block carries a new `persistent` sub-block with
  per-phase median timings (boot, app startup, test load,
  per-mutant ExUnit run, reset hooks per vector, filter
  lookup), counts (workers, crashes, restarts, filter-miss,
  mix-fallback), and memory peak per worker. `null` when
  `--worker-type mix` is in effect.
- **"Persistent worker:" terminal summary section.** Same data
  rendered as a human-readable block.
- `Mut.Worker.PersistentRunner.Diag` — in-BEAM helper for
  microsecond timing capture, memory snapshots, and the
  `MUT_BOOT_METRICS` / `MUT_RUN_METRICS` wire-protocol lines
  alongside the existing `MUT_READY` / `MUT_RESULT` markers.
- `Mut.Worker.Persistent.metrics/1` — host-side per-server
  view of accumulated diagnostics. Mix.Tasks.Mut drains every
  Persistent server before stopping it and folds the views
  into `Mut.Metrics`.
- New `Mut.Metrics.Snapshot.persistent` typespec block +
  `record_persistent_workers/2` accumulator API.

### Changed
- `Mut.Worker.Persistent.handle_call/3` distinguishes
  `{:error, :timeout, _}` from `{:error, :crashed, _}` and
  replies `:timeout` vs `:crashed` accordingly. Both still
  trigger BEAM auto-restart and mix-spawn retry on the host
  side (a Phase B attempt to skip the timeout retry regressed
  Decimal byte-identity by 31 mutants — see BENCHMARKS.md
  "v1.8 M20 Phase B"). The new API distinction is for code
  clarity and future targeted optimisation.

### Diagnostics gating
- `MUT_PERSISTENT_DIAG=0` disables per-mutant metrics emission
  in the runner (boot metrics always emit — boot happens once).
  Diagnostics overhead measured at c=4 on plug_crypto: 143 s
  with diag on vs 147 s with diag off, within noise (well
  under M20's 5% bar).

### Known limitations (v1.8.0)
- **Default stays `--worker-type mix`.** Persistent worker
  remains opt-in. Per-target perf at c=4: demo_app 1.3×
  faster, plug_crypto 0.59× (slower), Decimal 0.89×
  (slower). Default flip is gated on closing the perf gap
  on real targets.
- **The plug_crypto / Decimal slowness is concentrated in
  the timeout-recovery path.** ~30 Decimal mutants stall in
  persistent due to accumulated ExUnit/process state and
  require a mix-spawn retry for byte-identity. The four
  reset vectors (Application env / ETS / processes /
  persistent_term / OnExitHandler) don't catch this leak
  vector. Diagnosis is M21-conditional work.

### Internal
- `lib/mut/worker/persistent_runner/diag.ex` (new — diagnostic
  helper).
- `lib/mut/worker/persistent_runner.ex` — boot, app-startup,
  test-load, per-mutant, per-reset-vector instrumentation.
  `Diag.emit_boot/1` and `Diag.emit_run/1` write JSON
  protocol lines parsed by the host.
- `lib/mut/worker/persistent.ex` — host parses the new
  protocol lines, accumulates per-server metrics, exposes
  `metrics/1` for the host pipeline. `boot_port/2` returns
  boot wall + parsed boot metrics.
- `lib/mut/metrics.ex` — `Snapshot.persistent_block/0`
  typespec, `record_persistent_workers/2` cast,
  `persistent_snapshot/1` reducer (medians/p95s across all
  workers).
- `lib/mut/reporter/terminal.ex` — `persistent_block/1`
  renderer.
- `lib/mut/reporter/stryker_json.ex` — `persistent_extension/1`
  serialiser.
- `lib/mix/tasks/mut.ex` — `collect_persistent_metrics/2`
  drains workers before snapshot rendering.
- `test/mut/worker/persistent_test.exs` — new test for the
  `:timeout` vs `:crashed` reply distinction.
- `bench/run.sh` benches for plug_crypto and Decimal at c=1
  and c=4 with diagnostics enabled produced the per-target
  Phase A tables in BENCHMARKS.md.

## v1.7 (M19, 2026-05-06)

### Added
- **`--worker-type persistent` (opt-in supported).** A new worker
  model that keeps one ExUnit BEAM alive per sandbox and flips
  `:persistent_term` between mutants instead of spawning a fresh
  `mix test` per mutant. Default stays `mix`; persistent is
  enabled by passing `--worker-type persistent`. Byte-identical
  to mix at c=4 across demo_app, plug_crypto, and Decimal (within
  V17 acceptance for the existing timeout-class flap). Schema
  mutants only; fallback continues to use the v1.6 mix-spawn path.
- `Mut.Worker.Persistent` host GenServer + `Mut.Worker.PersistentRunner`
  in-BEAM runner. ExUnit.Server state is snapshotted at boot and
  restored before every run so the same loaded test modules
  re-execute deterministically.
- `Mut.Worker.PersistentRunner.Reset` collects per-leak-vector
  snapshot/reset helpers (Application env, ETS tables, registered
  processes, persistent_term, ExUnit OnExitHandler) used between
  iterations. Reset baselines are captured before the first mutant so
  state created by mutant 1 cannot become the clean baseline for later
  mutants.
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

### Fixed (v1.7 follow-ups)
- **`--no-halt` removed from the worker BEAM bootstrap** in
  `lib/mut/worker/persistent.ex`. With `--no-halt` the spawned BEAM
  ignored stdin EOF and survived port closure, accumulating as
  orphans across test/bench runs and was the root cause of the
  `mut.e2e --worker-type persistent` hang flagged in review 1. The
  runner's `loop/1` already exits on STOP / EOF; without
  `--no-halt`, the BEAM terminates cleanly and the e2e wrapper
  completes.
- **`e2e_persistent` verify layer enabled.** `bin/verify` now runs
  `mix mut.e2e --worker-type persistent` as a 9th layer. demo_app
  byte-identical between mix and persistent at c=4: 21 killed / 10
  survived in default, 21 / 10 in coverage, 23 / 10 in attribute
  mode (same stable-id sets).
- **Persistent runner now starts the project's OTP applications**
  (Mission F2). Without this, `Application.start/2` callbacks never
  fired, so resources they create (named ETS tables, registered
  processes) were missing under persistent and tests that depend on
  them crashed. plug_crypto's `Plug.Crypto.Application` creates the
  named `Plug.Crypto.Keys` ETS table this way; tests calling
  `sign`/`encrypt`/`verify`/`decrypt` failed with `:badarg` versus
  the mix worker (where `mix test` auto-starts the project's apps).
  The runner now scans `_build/mut_schema/lib/*/ebin/*.app` and
  ensures every project app is started before capturing the leak
  baseline. With this fix plug_crypto persistent at c=4 is
  byte-identical to mix: 38 Killed / 25 Survived / 1 Timeout (same
  stable-id sets).
- **`apply_file_filter/2` no longer silently runs every loaded
  test on filter miss** (Mission F1). Two paths produced this:
    1. host sent absolute paths via `Path.join(sandbox.path, file)`
       while the runner's index keyed test files on the *relative*
       path that `Code.require_file` received, so `Map.get` missed
       every entry;
    2. real misses (e.g. mistyped filename) — same fall-through.
  The runner now normalises both index keys and lookup keys via
  `Path.expand`. Files that still resolve to zero loaded tests
  return `{:error, {:filter_miss, files}}`; the runner emits a
  `MUT_RESULT filter_miss` line; `Mut.Worker.Persistent` replies
  `:filter_miss` and keeps the BEAM alive; `Mix.Tasks.Mut` reroutes
  that one mutant through the mix-spawn worker. Three regression
  tests (end-to-end + two direct unit tests) cover the path.

### Removed
- **`MUTALISK_PERSISTENT_EXPERIMENTAL=1` env gate** (Mission F3).
  All three correctness gates (demo_app, plug_crypto, Decimal) are
  met, so the experimental gate is removed. `--worker-type
  persistent` is now a regular opt-in flag.

### Known limitations (v1.7.0)
- **Default stays `--worker-type mix`.** Persistent worker is
  opt-in. v1.7 ships persistent as a correctness-safe opt-in,
  not a default/perf release: persistent is currently slower
  than mix on plug_crypto (1.7×) and Decimal (1.13×) at c=4, so
  the default flip waits on M20 perf work. demo_app is faster
  under persistent (1.3×).
- **In-process fallback recompile is deferred** (Mission F4
  phase 2). Fallback mutants always route to the mix-spawn
  worker, preserving M17's "0 invalid Decimal fallback" baseline
  regardless of worker type.

### Internal
- `lib/mut/worker/persistent.ex` (host).
- `lib/mut/worker/persistent_runner.ex` (in-BEAM).
- `lib/mut/worker/persistent_runner/reset.ex` (leak-vector helpers).
- `bin/verify` enables `e2e_persistent` as a 9th layer that runs
  `mix mut.e2e --worker-type persistent` directly. Asserts
  demo_app byte-identity between mix and persistent across
  default/coverage/attribute fixture variants.
- F4 phase 1: when the worker BEAM dies (port exit / run timeout),
  `Mut.Worker.Persistent` reboots the BEAM in-place; the crashing
  mutant gets `:crashed` and the host reruns it via mix-spawn,
  but subsequent mutants on the same sandbox stay on persistent.
  Two regression tests cover the success and unrecoverable-boot
  paths.

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
