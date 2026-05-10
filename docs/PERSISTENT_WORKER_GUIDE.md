# Persistent worker guide

> **Status:** opt-in. The default worker remains `--worker-type mix`.
> The persistent worker is byte-identical to mix on the reference
> targets (demo_app, plug_crypto, Decimal). M25 OSS validation
> (v1.10) found drift on real-world targets — see "What doesn't
> work yet" below for specifics. Use it when you want Mutalisk to
> be faster on a project shape we've validated; stay on the
> default when you want the most boring possible execution model.

## TL;DR

Pass `--worker-type persistent` and you get a dedicated ExUnit BEAM
per sandbox that stays warm across mutants instead of paying mix-test
boot cost on every mutant. Faster on real targets (~2× on Decimal at
`c=4`). Outcomes are byte-identical to the mix worker on the v1.8
reference targets (demo_app, plug_crypto, Decimal); M25's broader
OSS matrix surfaced drift on macro-heavy and Mox-class targets
(see below).

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
If your suite uses any of these, stay on the default mix worker.

The first four are persistent-resident patterns we've documented
since v1.7. The remainder were surfaced by M25's 5-target OSS
validation matrix at v1.10.

- **NIFs that don't tolerate `:code` reload.** The fallback path
  recompiles modules in-process using `Code.compile_file/1` and
  swaps them via `:code.purge/1` + `:code.load_file/1`. Native
  resources captured pre-reload may break.
- **Tests that crash the BEAM.** A segfault or `:erlang.halt/0`
  takes the whole worker down. The host auto-restarts the BEAM and
  routes the failing mutant via mix-spawn, so correctness is
  preserved — but performance suffers if a project crashes often.
- **Tests depending on global per-test setup ordering.** ExUnit's
  module load order is captured once at boot; if your suite
  mutates that order at runtime, the persistent worker won't see
  the changes.

### M25-surfaced unsupported patterns (v1.10)

The following patterns produce **byte-identity drift** between
mix-spawn and persistent runs — outcomes diverge in ways that are
not timeout-flap and are not recoverable via the in-process
fallback retries. Use `--worker-type mix` on these project shapes
until the underlying drift is closed.

- **Mox cluster/peer-state leaks (residual after M28).** v1.11
  M28 added a `Mox.Server` reset hook that terminates and restarts
  Mox's `NimbleOwnership` worker via the supervisor between
  mutants. The hook successfully clears local-node mock registry
  state (expectations, allowances, history, stubs). However, mox
  v1.2.0's own self-tests include `MoxTest.ClusterTest`, which
  spawns peer Erlang nodes via `:peer.start/1` and runs Mox
  across the cluster. The peer-node controllers are torn down by
  the `processes` reset hook, but residual cluster-state leaks
  manifest as 3 of mox v1.2.0's 38 mutants flipping
  `mix=Survived → persistent=Killed`. All 3 are killed by
  `MoxTest.ClusterTest` tests; non-cluster Mox usage is now
  byte-identical between worker types. A project using Mox in
  the standard local-node way is unaffected; a project running
  its own multi-node Mox tests will still see drift. Closing the
  cluster-state residual is open at v1.11 close: M29's spike
  declined helper-process isolation, and a multi-node-aware
  reset hook is v1.12+ scope.
- **Compile-time docs/validation pipelines that use the same guards
  being mutated.** When a library's compile-time hook (e.g.,
  `nimble_options`'s `NimbleOptions.Docs.generate/1` evaluated at
  module-compile time, or `gettext`'s `Gettext.Compiler.__before_compile__/1`)
  walks its own schema using the very type guards a mutant
  rewrites, the in-process recompile pipeline raises
  `FunctionClauseError` / `ParallelCompiler.async/1` errors that
  mix-spawn's fresh-process compile evaluates differently. Mutalisk
  catches this as `:unknown` / `:parse_error` recompile category
  and re-routes to mix-spawn, but a residual class manifests as
  `MismatchedDelimiterError` / `SyntaxError` in the in-process
  parser path that mix-spawn parses cleanly. Visible in metrics as
  `parse errors:` count > 0.
- **`gettext` v1.0+ projects are mix-only (M31 closure).**
  Persistent worker boot fails:
  `Gettext.Compiler.__before_compile__/1` calls
  `Kernel.ParallelCompiler.async/1` which requires the calling
  process to be running under a parallel-compile context. The
  persistent worker's test-load step runs outside that context,
  raising `ArgumentError: cannot spawn parallel compiler task`
  before any mutant runs.

  M31 evaluated the two paths from PLAN.md:

  - **Path (i): wrap the test-load step in
    `Kernel.ParallelCompiler.compile/2`.** Would establish the
    required parent context, but introduces a non-trivial
    refactor of the runner's boot path (compile + load are
    interleaved with reset-baseline capture, which assumes a
    plain process), and the M29 spike's measurement of
    `Kernel.ParallelCompiler` for the fallback path showed
    helper-process isolation does not subsume the warm-state
    drift class anyway. Investing the plumbing buys gettext
    boot, but other gettext-class drift would surface
    immediately and is itself unaddressed.
  - **Path (ii): formally exclude gettext-class as mix-only.**
    Boot-warning catalogue's `:gettext` row makes this explicit
    and points users at `--worker-type mix`. Gettext-using
    projects already routed there at v1.10 by M25's bench
    classification.

  v1.11 takes Path (ii). The persistent boot warning fires on
  any project with `:gettext` in its compiled-dep tree; the
  message names gettext-class as unsupported and points to
  `--worker-type mix`. Path (i) remains a v1.12+ option if the
  underlying compiler-plumbing cost drops or if a
  `gettext`-shape becomes a primary v1.12 acceptance class.
- **Ecto-class projects are mix-only (M30 closure).** v1.11 M30
  shipped `Mut.Worker.PersistentRunner.Reset.reset_ecto/0`, which
  walks ETS tables owned by `Elixir.Ecto.*`-named processes and
  calls `:ets.delete_all_objects/1` between mutants. Re-bench on
  ecto v3.13.6 (994 mutants): drift dropped from 226 to 231 — i.e.
  the ETS reset has no measurable effect on the dominant warm-
  state classes. Diagnosis from the M30 measurement:

  - The 113 `RuntimeError → Killed` flips are NOT cache-state
    leaks. They come from supervisor-init reordering: mix-spawn
    re-runs `Application.start/2` on every fallback mutant, so any
    mutation that breaks supervised initialization surfaces as a
    test-framework RuntimeError. Persistent doesn't re-run
    `Application.start/2` — it loads apps once at boot — so the
    same mutation runs against an already-initialized supervisor
    tree and the affected test simply fails (`Killed`).
  - The 67 `Survived → Killed` flips are partly leaked Ecto.Query
    planner cache and partly the same supervisor-init effect on
    different test paths.
  - The 22 `Killed → Survived` flips are the inverse: persistent's
    cached planner state masks behavior change mix-spawn would see.

  Reset hooks cannot close the supervisor-init path; that requires
  re-running `Application.start/2` per mutant, which is
  fundamentally what `--worker-type mix` already does and what
  persistent is designed to avoid. **For Ecto-class projects, use
  `--worker-type mix`.** The persistent worker's reset hook stays
  in place as defense-in-depth (no-op when Ecto isn't loaded; very
  cheap when it is) but does not change the recommendation.
- **HTTP-client / process-pool warm state.** Projects with HTTP
  clients (`mint`, `finch`, `hackney`, `gun`) or generic process
  pools (`nimble_pool`, `poolboy`, `connection`). M27 mint v1.8.0
  measured 49/250 mutants (19.6%) where `mix=Survived →
  persistent=Killed` — the warm BEAM accumulates sockets, pool
  workers, and registry entries across mutants in a way mix-spawn
  re-creates per run. `nimble_pool` v1.1.0 shows the same direction
  at 4/28 (14.3%). Different root cause from Ecto warm state, same
  drift direction. Reset hooks (`processes`) clear named process
  trees but not the longer-lived registry entries these libraries
  cache. Auto-classified as `:pool_warm_state` by `mix mut.drift`.
- **SchemaPlacer escaped-quote crash.** Files containing strings
  with embedded `\\"..\\"` sequences (HTML / header content /
  fixture stubs) crash `Mut.SchemaPlacer.render/1` via
  `Code.format_string!/2`. Mutalisk regression; both
  `--worker-type mix` and `--worker-type persistent` fail
  identically. Surfaced by M27 on `phoenix_html` v4.3.0,
  `plug` v1.19.1, and `phoenix_pubsub` v2.2.0. Targets crash
  before any mutant runs. v1.12 follow-up; tracked in BENCHMARKS.md.
- **Macro-bodies with literal interpolated heredocs.** Until
  Elixir's upstream `Macro.to_string/1` bug on heredoc
  `\`-continuation is fixed, mutants in files with that shape
  (gettext v1.0.2 `lib/gettext/extractor_agent.ex:83`,
  `lib/gettext/plural.ex:79`) round-trip via Mutalisk's
  heredoc-delimiter-stripping workaround. Output is correct
  (single-line `"..."` strings round-trip cleanly) but produces
  visible diffs vs source — purely cosmetic; correctness preserved.

## Boot-time warning

When `--worker-type persistent` boots, Mutalisk scans the project's
compiled-dep tree (`_build/mut_schema/lib/<app>/ebin`) for
known-bad target signatures and emits a one-line stderr warning
per detection BEFORE the first worker BEAM starts:

```
[mutalisk] Warning: persistent worker detected Mox-class projects:
  Mox.Server mock-registry leaks across mutants under persistent.
  Known drift exists for this class — consider --worker-type mix.
  See docs/PERSISTENT_WORKER_GUIDE.md.
```

Triggers (v1.11 catalogue):

| Detected dep | Signature | Suggested action |
|---|---|---|
| `:mox` | `:mox` | M28's reset hook closes local-node Mox state. Use `--worker-type mix` if your suite spans Erlang nodes (residual cluster-state drift). |
| `:ecto`, `:ecto_sql` | `:ecto` | M30 confirmed Ecto-class drift is supervisor-init structural, not cache-state. Use `--worker-type mix` for Ecto-class projects. |
| `:gettext` | `:gettext` | M31 confirmed gettext-class is mix-only (Gettext.Compiler.__before_compile__/1 boot-fails outside a parallel-compile parent). Use `--worker-type mix`. |

The warning is a *heads-up*, not a diagnosis. A clean Ecto setup
will still trigger it; a Mox-using project that already knows the
limitation will still trigger it. The v1.11 catalogue retains all
three rows: M28's reset hook closed local-node Mox state but the
cluster-state residual remains; M30 confirmed Ecto-class is
structurally mix-only (supervisor-init reordering is not
addressable by reset hooks); M31 confirmed Gettext-class is
mix-only on `Kernel.ParallelCompiler` parent-context grounds.
Rows are removed only when the entire drift class closes — none
of the three closed in v1.11.

To suppress for CI cleanliness:

```sh
mix mut --worker-type persistent --quiet-boot-warning
# or in config :mut:
config :mut, quiet_boot_warning: true
```

The warning lands on stderr; Stryker JSON output and stdout-parsed
terminal assertions are unaffected. The warning fires regardless
of whether drift will actually manifest on this run — its job is
to surface known-class limitations to users who don't know to
look for them.

HTTP-client / process-pool projects (`mint`, `finch`,
`nimble_pool`) are NOT yet in the boot-warning catalogue. M27
surfaced this drift class but extending the detector is a v1.12
follow-up — for now, run `mix mut.drift --target <name>` after
your first persistent run and look for the `:pool_warm_state`
bucket.

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
  Stays opt-in in v1.10 per M25's Decision 1: aggregate kill rate
  passes thresholds (62.3% across n=419 / 0 invalid) but the
  mox/ecto persistent-drift trigger fires the keep-opt-in branch.
  Re-evaluated in v1.11+ once M28 (Mox.Server reset) and M29 (Ecto
  warm-state closure) land.

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
