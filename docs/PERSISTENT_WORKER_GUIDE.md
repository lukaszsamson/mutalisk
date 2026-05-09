# Persistent worker guide

> **Status:** opt-in. The default worker remains `--worker-type mix`.
> The persistent worker is production-ready as of v1.8 against the
> reference targets (demo_app, plug_crypto, Decimal). Use it when
> you want Mutalisk to be faster; stay on the default when you want
> the most boring possible execution model.

## TL;DR

Pass `--worker-type persistent` and you get a dedicated ExUnit BEAM
per sandbox that stays warm across mutants instead of paying mix-test
boot cost on every mutant. Faster on real targets (~2× on Decimal at
`c=4`). Outcomes are byte-identical to the mix worker.

```sh
MIX_ENV=test mix mut --worker-type persistent
```

That's it. Read on if you want to know whether it's right for your
project, or what to do if it isn't.

## When to use it

The persistent worker amortizes mix-test boot cost (compile check,
deps loading, `:application` start, ExUnit setup) across all the
mutants that share a sandbox. The bigger that fixed cost is relative
to the per-test runtime, the more you save.

**Use it when:**
- Your baseline `mix test` boots take 2 s or more.
- Your test suite has 50+ mutants worth running.
- You're running `--concurrency 4` or higher.

**Don't bother when:**
- Your project boots and runs ExUnit in under a second total.
- You only have a handful of mutants (the boot cost is amortized
  over too few iterations to matter).
- You're debugging a specific mutant interactively.

## What works

The persistent worker is a normal ExUnit BEAM that loads your test
modules once and resets state between mutants. Anything that survives
that reset model is supported:

- Standard ExUnit tests, sync or async.
- Plain library code.
- `Application.start/2` callbacks. Project apps are auto-started at
  worker boot. Named ETS tables, registered processes, and similar
  resources created in `start/2` are available to your tests.
- `:cover`-instrumented tests under `--selection coverage` /
  `--selection coverage_with_static_fallback`.
- Tests using `setup`, `setup_all`, `on_exit`. The leak-vector reset
  hooks restore state between mutants.

## What doesn't work yet

Some patterns are known not to play well with the in-memory model.
If your suite uses any of these, stay on the default mix worker:

- **NIFs that don't tolerate `:code` reload.** The fallback path
  recompiles modules in-process using `Code.compile_file/1` and
  swaps them via `:code.purge/1` + `:code.load_file/1`. Native
  resources captured pre-reload may break.
- **Tests that crash the BEAM.** A segfault or `:erlang.halt/0`
  takes the whole worker down. The host auto-restarts the BEAM and
  routes the failing mutant via mix-spawn, so correctness is
  preserved — but performance suffers if a project crashes often.
- **Heavy `Mox` usage.** Not yet validated end-to-end. The next
  validation milestone should cover this; until then, mix is safer
  if your suite leans on Mox.
- **Tests depending on global per-test setup ordering.** ExUnit's
  module load order is captured once at boot; if your suite
  mutates that order at runtime, the persistent worker won't see
  the changes.

## Reading the persistent metrics block

After a `--worker-type persistent` run, the terminal summary
includes a `Persistent worker:` block. The interesting parts:

```
Persistent worker:
  workers:     4
  boot:        median 1.4 s (max 1.8 s)
  app startup: median 320 ms (total apps: 6)
  test load:   median 80 ms (total files: 12)
  mutant run:  median 110 ms (p95 240 ms, n=312)
  reset hooks:
    application_env: 1.2 ms
    ets:             0.3 ms
    processes:       0.4 ms
    persistent_term: 0.2 ms
    on_exit:         0.1 ms
  filter lookup: 0.6 ms
  crashes: 0  restarts: 0  filter-miss: 0  in-process compile errors: 0  mix fallbacks: 0
  memory: peak 280.0 MB total, 180.0 MB processes
```

Counters worth watching:

- **crashes / restarts.** The worker BEAM crashed mid-run. Single
  crashes can happen in a noisy test; sustained crashes mean the
  BEAM is unhappy with your suite's interaction with the reset
  model.
- **filter-miss.** A mutant's selected test files didn't map to any
  loaded test in the persistent worker. The host re-runs that
  mutant via mix-spawn, so it's a perf hit, not a correctness one.
- **in-process compile errors.** Fallback patches that didn't
  compile in-process. Almost always a property of the mutant, not
  the worker — but if you see lots of these on patches that *do*
  compile in mix-spawn, file a bug.
- **mix fallbacks.** Sum of the prior three: how often the host
  re-routed work via mix-spawn. Low is good.

The same numbers live in `mutalisk.persistent` in the Stryker JSON
report — durable for CI dashboards.

## When to fall back to mix

Mutalisk emits a single hint line at run end if any of three
thresholds is exceeded:

- **Crash rate > 10%.** The worker BEAM is dying often enough that
  per-mutant cost is dominated by restart wall-clock. Mix-spawn is
  more predictable.
- **Filter-miss rate > 25%.** Most mutants are bouncing back to
  mix-spawn anyway; the persistent worker is paying boot cost for
  little benefit.
- **In-process fallback compile-error rate > 5%.** Your mutants
  are stressing the in-process recompile path harder than expected.

The hint is informational; nothing auto-switches. Read the metrics
block above the hint, decide whether the cost is worth the speed, and
either rerun with `--worker-type mix` or accept the noise.

## Configuration

Relevant flags:

- `--worker-type mix | persistent` — pick the worker. Default `mix`.
- `--test-timeout-ms N` — per-test ExUnit timeout in milliseconds.
  Default `10000` (1-second min, 10-minute max). Applied to both
  worker types so they remain comparable. Raise this if your suite
  has legitimately slow tests; otherwise the default catches
  mutation-induced infinite loops fast.
- `--concurrency N` — number of parallel sandboxes. The persistent
  worker spawns one BEAM per sandbox, so a `c=4` run holds 4 worker
  BEAMs simultaneously. Watch `memory: peak ... total` if you raise
  this on smaller machines.
- `--selection coverage_with_static_fallback` — coverage-based test
  selection. Validated against persistent in the e2e test suite;
  byte-identical with mix+static.
- `--enable body_literal` — opt in to integer / boolean body-literal
  mutators (M23). These route through the fallback engine; expect
  added fallback wall-clock proportional to the literal count.
  Currently opt-in pending the M24 OSS-target validation matrix.

Configuration via `config :mut`:

```elixir
config :mut,
  worker_type: :persistent,
  test_timeout_ms: 30_000
```

CLI flags override config.

## Limitations

- One worker BEAM per sandbox, holding all loaded test modules in
  memory. Large suites use proportionally more RAM.
- Full project app discovery happens at worker boot. Apps that
  register the same name as another already-running OTP app are
  not isolated; tests that depend on registered-name uniqueness
  may collide if your project has duplicates.
- The fallback path's in-process recompile uses `:code.purge/1` +
  `:code.load_file/1`, which works for normal Elixir modules but
  may surprise modules with module-level `__on_load__` hooks.
- If something seems off, run with `--worker-type mix` to confirm.
  Persistent and mix are byte-identical on outcomes against the
  reference targets — divergence is a bug, please report.

## Reporting issues

If the persistent worker produces different mutant outcomes than
the mix worker on your project, that's a bug. Capture:

1. The full `mix mut --worker-type persistent` output.
2. The same run with `--worker-type mix` for comparison.
3. The `mutalisk.persistent` block from the Stryker JSON.

File at the project's issue tracker. Outcome divergence is the
most important signal we have for guiding the v1.9+ stabilization
work.
