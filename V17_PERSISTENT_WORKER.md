# V1.7 Persistent Worker Design — `Mut.Worker.Persistent`

Status: design (M18 deliverable, M19 implements). Authored after M17 closed v1.6 with parallel workers as the default and Decimal landing at 11.0 min wall.

## Why this milestone exists

The PROMPT_16 spike at `bench/spike/persistent_beam.exs` measured cold 8.8 ms vs hot 80 µs for an in-process `ExUnit.run/0` re-invocation — a 110× speedup *within the same BEAM*. Compared with the production cold-start path (~5 s of `mix test` BEAM boot + project load + test compile + execute), the projected hot per-mutant cost is **1–10 ms** for non-trivial test bodies.

That projects Decimal to **≈ 1 minute** wall in single-process mode, with linear scale-out across multiple sandbox BEAMs. v1.7's premise is that this speedup is real and the implementation cost is bounded; this document defines the contract that makes the implementation defensible.

For background see:
- `V16_PERFORMANCE.md` — the recommendation that ordered v1.6/v1.7.
- `bench/spike/persistent_beam.exs` — the spike script and its measurements.
- `BENCHMARKS.md` "Concurrency speedup curve (M17)" — current state.

## Contract

Single module: `Mut.Worker.Persistent`. Single GenServer per sandbox.

```elixir
defmodule Mut.Worker.Persistent do
  @type server :: GenServer.server()
  @type mutant_id :: non_neg_integer()
  @type test_file :: Path.t()

  @spec start_link(Mut.Sandbox.t(), keyword) :: GenServer.on_start()
  # Spawns a child BEAM via Port over the sandbox, loads ExUnit + the
  # target's compiled .beam files + the user's test_helper.exs +
  # discovered test files, then waits for a :ready signal before returning.

  @spec run_mutant(server, mutant_id, [test_file], keyword) ::
          {:ok, Mut.Worker.Result.t()} | {:error, :crashed | :timeout | term()}
  # Flips :persistent_term to mutant_id, calls ExUnit.run/0 (filtered to
  # the supplied test_files), captures the result. Blocks until the run
  # completes or hits the per-mutant timeout.

  @spec stop(server) :: :ok
  # Sends :stop to the child BEAM, waits for clean exit, closes the port.
end
```

Result shape mirrors `Mut.Worker.Result` so `Mix.Tasks.Mut`'s recording path stays unchanged. The host caller decides which worker type runs each mutant (see "Concurrency interaction" below); the result type is identical.

## Lifecycle

Per sandbox, in order:

1. **Pool creation** — `Mut.Sandbox.create_pool/2` runs at `Mix.Tasks.Mut`'s `execute_plan` entry, exactly as in v1.6. No change.
2. **Persistent worker start** — for each sandbox, spawn one persistent BEAM via Port. Inside that BEAM:
   - Add the sandbox's `_build/mut_schema/lib/*/ebin` paths via `-pa`.
   - `ExUnit.start(autorun: false, formatters: [...])`.
   - `Code.require_file/1` for the user's `test/test_helper.exs`.
   - `Code.require_file/1` for each discovered test file.
   - Send `{:ready, self()}` back to the host port.
3. **Per-mutant** — host calls `run_mutant(server, mutant_id, test_files)`. The worker:
   - `:persistent_term.put({Mut.Runtime, :active_mutant}, mutant_id)`.
   - Resets per-mutant ExUnit state (see ExUnit state reset strategy).
   - Calls `ExUnit.run/0` with `:include`/`:exclude` filtered to load only `test_files` (see "ExUnit run filter"). Captures the failures count, durations, killing test name.
   - Replies `{:ok, %Mut.Worker.Result{}}`.
4. **Mutant timeout** — if `run_mutant/4` does not reply within `timeout_ms`, the host sends `:cancel`. The worker either returns `{:error, :timeout}` or, if it cannot interrupt cleanly (e.g., a mutant that infinite-loops a NIF), the host kills the BEAM and the supervisor restarts it (see "Crash recovery").
5. **Pool drain** — at the end of `execute_plan`, host calls `Mut.Worker.Persistent.stop/1` for each sandbox's worker, then `Sandbox.destroy_pool/1` as today.

The persistent BEAM stays alive **for the duration of `mix mut`**, not across runs. There is no cross-run state.

## Isolation model

What is shared across mutants in the same persistent BEAM:

- **Compiled modules.** All target + dep `.beam` files load once. Schema mutants flip via `:persistent_term`; **no recompilation is needed for schema**. Fallback mutants need fresh `.beam` (see "Fallback mode" below).
- **ExUnit configuration.** `ExUnit.configure/1` runs once at startup. Settings (e.g., `seed`, `trace`) are deterministic across mutants.
- **Loaded test files.** Each test file is loaded by `Code.require_file/1` exactly once. Subsequent `ExUnit.run/0` invocations re-execute the test cases without re-loading.
- **`Application` env at startup.** Whatever the user's `test_helper.exs` set up at boot is shared.

What is reset between mutants:

- **Active mutant id** — `:persistent_term.put({Mut.Runtime, :active_mutant}, id)` before each run.
- **ExUnit accumulated state** — see ExUnit state reset strategy.

What **is not** automatically reset:

- **`Application.put_env`** mutations made by tests.
- **ETS tables** owned by tests.
- **Mocked modules** (e.g., `:meck` overrides) installed by tests.
- **Process registry** entries created by tests.
- **`:persistent_term`** entries set by tests under non-mutalisk keys.

These are the leak vectors the reset strategy must address.

## ExUnit state reset strategy

For each leak vector, pin a reset approach. References use Elixir 1.19's `lib/ex_unit/lib/ex_unit/...` paths.

### Per-iteration reset hooks

ExUnit calls `setup_all` once per module per **process**, not per `ExUnit.run/0` invocation. To force re-execution of `setup_all` between mutants we must clear `ExUnit.OnExitHandler` and the per-test process state:

1. After each `ExUnit.run/0`, the worker invokes `:ets.delete_all_objects/1` on the `ExUnit.OnExitHandler` ETS (`ex_unit/on_exit_handler.ex` — public ETS table named `ExUnit.OnExitHandler`). This drops any lingering `on_exit` callbacks.
2. The worker resets `ExUnit.Server`'s loaded-tests state via the public `ExUnit.Server.modules_loaded(false)` call to mark the suite as not-yet-loaded; then re-asserts via `ExUnit.Server.modules_loaded(true)` so the next `ExUnit.run/0` rediscovers loaded test modules. This is the seam the spike script does **not** exercise — the design must validate this works.
3. The worker invokes `ExUnit.start(autorun: false)` again. Re-starting is idempotent; it ensures the run-counter resets so the formatter sees a fresh suite.

### Application env mutations

Detection: at startup, snapshot `Application.get_all_env(:mutalisk_target_apps)` for each app the user declares (or, conservatively, all apps loaded). After each `ExUnit.run/0`:

- Diff the current `Application.get_all_env/1` against the snapshot.
- For each delta: `Application.put_env/3` to restore, or `Application.delete_env/2` if the snapshot didn't have the key.

Cost: one `Application.get_all_env/1` per app per mutant. With 5–10 apps and ~10 keys each, this is sub-millisecond.

Risk: the user's `test_helper.exs` may legitimately set env values that tests depend on; those are in the snapshot, so they're preserved. The risk is that a test sets a value the next test depends on **without** going through the snapshot; that pattern is brittle and `--worker-type mix` will be the recommended fallback.

### ETS tables owned by tests

Detection: `:ets.all/0` snapshot at startup. After each run, diff:

- New tables that didn't exist: `:ets.delete/1`.
- Tables that existed: leave them. (We can't safely truncate a pre-existing table because v1.5's coverage oracle uses ETS internally.)

Risk: a test that writes to a *pre-existing* ETS table leaves residue. This is the most common ETS-leak pattern; we can't fully isolate it from a persistent BEAM. Recommend: `--worker-type mix` for users who flag this in test_helper.

### Mocked modules

Mock libraries (`:meck`, `Mox`, etc.) install replacement modules. Detection:

- Snapshot loaded modules at startup via `:code.all_loaded/0`.
- After each run, find newly-loaded modules whose name matches `:meck` or `Mox` patterns; if any exist, instruct the user to use `--worker-type mix` (don't try to surgically un-mock — too brittle).

This is a documented unsupported pattern, not a reset hook. M19 detects, warns, and falls back per-mutant.

### Process registry / spawned processes

Tests sometimes start named processes (`Process.register/2`, `:gen_server.start_link(name: ...)`) and don't clean up. Detection:

- Snapshot `Process.registered/0` at startup.
- After each run, `Process.exit(pid, :shutdown)` for any newly-registered named process where `Process.alive?(pid)`.

Risk: if a test registers a name that the next test happens to need, kill-and-restart may break it. This is fragile-test territory; document the pattern.

### Async test residue

ExUnit's async tests spawn `ExUnit.AsyncCase` worker processes. After `ExUnit.run/0` returns, async workers may still be terminating. Mitigation:

- The worker explicitly calls `ExUnit.Server.await_all_async/1` (or equivalent — verify the API in M19) before declaring the run complete.
- For runs where this is impossible (runaway async test), the per-mutant timeout fires.

### `:persistent_term` entries set by tests

The active-mutant key (`{Mut.Runtime, :active_mutant}`) is reset on every run. Other persistent_term entries are not. This is rarely a leak vector (most tests don't write persistent_term), but if it surfaces, document.

## ExUnit run filter

`ExUnit.run/0` runs all loaded test cases. To target a specific subset of test files for a mutant, use:

- `ExUnit.configure(include: [...], exclude: [...])` per run.
- For per-file filtering (the M17 selection pipeline produces test file paths, not tag patterns), use `ExUnit.Case.test/3`'s `file:` metadata via `ExUnit.configure(only_test_ids: ...)`. The `only_test_ids` option exists in 1.19 and is the cleanest seam.

If `only_test_ids` proves insufficient, fall back to `ExUnit.run/2` with explicit test module filtering. M19 should validate which API survives across Elixir versions in our support range.

## Unsupported test patterns

Document in `mix help mut` and `lib/mix/tasks/mut.ex` `@moduledoc`:

- **Tests that mutate ETS tables they didn't create.**
- **Tests that install module mocks via `:meck`/`Mox` without per-test cleanup.**
- **Tests that depend on per-process compilation state (`Code.eval_file`, `:erlang.put`, etc.).**
- **Tests that crash the BEAM on failure** (e.g., raise from a NIF callback). These crash the persistent worker; v1.7 detects and falls back to `mix` worker for the next mutant.

Recommend `--worker-type mix` as the per-target opt-out. The current `mix`-spawning worker stays as a supported fallback in v1.7.

## Crash recovery

A mutant that triggers a crash inside the persistent BEAM kills the BEAM. Detection and recovery:

1. **Detection.** Host monitors the Port. When the Port closes unexpectedly (`{port, :exit_status, n}` for n != 0, or the Port dying altogether), the host knows the worker crashed mid-run.
2. **Result attribution.** The mutant the worker was processing at crash time gets `%Result{status: :error, recompile_category: nil, raw_output: "<crash log>"}`. We **do not** retry — once is the v1.7 contract, retry is v1.8 if observed crash rate matters.
3. **Restart.** Host calls `start_link/1` on the same sandbox. Loading ExUnit + tests takes ~100 ms; the next mutant resumes on the new BEAM. The sandbox's compiled `.beam` files survive on disk so the new BEAM picks them up cleanly.
4. **Repeated crashes.** If a sandbox's worker crashes ≥3 times within a single `mix mut` run, the host falls back to `Mut.Worker` (the existing mix-spawn path) for that sandbox's remaining mutants. Threshold is configurable; default is 3.
5. **Heartbeats.** Not in v1.7. Crash detection relies on Port exit; a hung BEAM is caught by per-mutant timeout, not heartbeat.

Crash isolation is a multiplier on per-mutant timeout cost, not on steady-state throughput. A sandbox that crashes once costs ~100 ms restart; one that crashes 3× falls back to mix worker for the rest of the run.

## Fallback mode in a persistent worker

Fallback mutants rewrite source. The persistent BEAM holds compiled modules; rewriting source needs a fresh `.beam`. Options:

1. **In-process recompile.** After applying the fallback patch, the worker runs `Kernel.ParallelCompiler.compile_to_path/2` inline (the exact path `Mut.Recompile` uses today, but in-process). Then `:code.purge/1` + `:code.load_binary/3` for the recompiled module. Cost: roughly the existing fallback recompile cost (3–5 s for Decimal) but no BEAM-spawn overhead.
2. **Skip persistent for fallback.** Run fallback mutants on the existing `Mut.Worker` (mix-spawn). Persistent worker handles schema only.

**Recommendation: Option 1.** The same `:code.load_binary` pattern is what `Mix.Tasks.Compile.Elixir` uses to swap modules in-place during recompile; the BEAM supports it. Schema and fallback share the persistent worker.

Risk: `:code.purge/1` blocks until no process holds a reference to the old module. With async tests this could deadlock. Mitigation: use `:code.delete/1` + `:code.purge/1` with a timeout; if purge fails, kill the persistent BEAM and restart (treat as a crash).

## Concurrency interaction

`--concurrency N` × persistent workers = N concurrent persistent BEAMs. Each owns one sandbox. The host's `Task.async_stream` dispatches mutants across sandboxes via `Mut.SandboxQueue` (the M17 plumbing).

Throughput model:
- Per-BEAM steady state: 1–10 ms per mutant (median; depends on test body).
- N=4 BEAMs at 1 ms = 4000 mutants/sec ceiling. Realistic: 250–500 mutants/sec on Decimal-class tests (10 ms median).
- Decimal is 456 mutants. At 250 mutants/sec sustained: ~2 sec compute + setup overhead. That's the v1.7 acceptance bar (~2 minutes total wall, dominated by initial BEAM startup × N + recompile cost for fallback mutants).

Lock contention: `Mut.LastKiller`'s Agent is shared across N BEAMs via the host. M17's audit established it stays sub-millisecond at expected rates; persistent workers don't push the rate appreciably higher because the bottleneck moves from `mix test` boot to ExUnit run, not to the host coordinator.

## v1.7 (M19) acceptance criteria sketch

- **Per-mutant median wall <50 ms on demo_app.** Steady-state hot run; first mutant per sandbox is allowed to be slower (BEAM boot + ExUnit start + test load).
- **Decimal ≤ 2 minutes wall at `--concurrency 4`** with persistent workers (vs. M17's 11.0 min on the mix-spawn path).
- **Outcomes byte-identical to M17** on demo_app, plug_crypto, Decimal — same Survived stable_id sets at every concurrency level.
- **`bin/verify`** adds an `e2e_persistent` layer running demo_app at c=4 with persistent workers; same plan composition, same outcomes.
- **Fallback mutants on Decimal** continue to land at 0 invalid (the M17 Phase B win must hold — no new infrastructure regression).
- **Crash recovery exercised** by a fixture mutant that intentionally raises in a setup_all; assert the persistent BEAM restarts and the next mutant runs cleanly.
- **`--worker-type mix` opt-out** is wired and tested.

## Implementation cost estimate

Refining PROMPT_16's ~590 LOC headline:

| Component | Est. LOC |
|---|---:|
| `Mut.Worker.Persistent` GenServer (host side: start_link, run_mutant, stop, monitor port, crash-restart) | 180 |
| Sandbox bootstrap script (in-BEAM script that loads ExUnit + tests + waits for messages) | 120 |
| Host ↔ worker protocol (Port message contract: ready, run, result, ping, stop) | 80 |
| ExUnit reset hooks (ETS snapshot + diff, Application env snapshot + diff, registered-process snapshot + cleanup) | 100 |
| ExUnit run filter (only_test_ids configuration; verify across Elixir versions) | 50 |
| Fallback in-process recompile + `:code.load_binary` flow + purge timeout | 80 |
| Crash detection + retry threshold + fallback-to-mix worker | 60 |
| `--worker-type mix\|persistent` flag + routing in `Mix.Tasks.Mut` | 40 |
| Tests (unit + integration on demo_app + crash-recovery fixture) | 220 |
| **Total** | **~930 LOC** |

The headline grew from 590 to 930 once we enumerated ExUnit reset hooks and crash recovery in detail. Still bounded; comparable to `Mut.Sandbox` + `Mut.Recompile` together.

## Risks and unknowns

| Risk | Severity | Mitigation |
|---|---|---|
| `ExUnit.Server.modules_loaded(false)` is private API in some Elixir versions | high | M19 must verify across the support range; if private, vendor a small shim or use `ExUnit.run/2` with explicit module list |
| `:code.purge/1` deadlocks on async-test residue | medium | Treat purge timeout as a crash; restart worker. Same recovery path as a runaway mutant |
| Application env diff misses a leak (e.g., test mutates env via `:application.set_env/3` directly) | medium | Snapshot `:application.get_all_env/1` (raw OTP API) instead of Elixir wrapper; covers both code paths |
| Mocked-module detection misses a less common library | low | Document the supported set; users can opt out via `--worker-type mix` per project |
| Per-mutant 1 ms means LastKiller / Metrics GenServer becomes the bottleneck | low–medium | M17 already documents the swap criterion (>~1000 record_kill/sec). Persistent workers may push us there; M19 includes a profiling pass |
| `only_test_ids` filter selects too many tests on suites with thousands of cases | low | Cap the filter; if filter set is large, fall back to running the full suite — it's the same on the cold path |
| ExUnit's failure detection assumes a fresh suite per `run/0` and we're feeding it a long-lived suite | medium | M19's first integration test is "run the same test 1000 times in one BEAM, fail rate stays at 0" |
| BEAM memory growth across 1000s of `ExUnit.run/0` invocations | medium | Monitor via the existing `Mut.MemoryWatchdog`; if RSS climbs, force `:erlang.garbage_collect/0` between mutants |
| Determinism: ExUnit's seed across persistent runs | low | Configure a fixed seed at startup; document the implication for user tests that use `ExUnit.configure(seed: 0)` |

The high-severity risk is the `ExUnit.Server` private API. If that turns out to be unworkable, the fallback is to run each `ExUnit.run/0` in a fresh **process** inside the persistent BEAM (still avoids the mix-test boot cost; loses some of the cross-mutant cache).

## What this does NOT change

- Mutator engines (schema vs fallback routing).
- Stable_id input or computation.
- Coverage selection model.
- Sandbox lifecycle (M17 plumbing stays).
- The `Mut.Worker` module — it stays as the `--worker-type mix` fallback, and is the default for any project that flags an unsupported pattern.
- Build-Path Contract.

## Out of scope for v1.7

- Cross-run persistent history.
- New mutators.
- Coverage default flip (still opt-in).
- Per-test-case attribution.
- Cross-machine distribution.

## Sequencing

M19 (v1.7 implementation) should land in this order:

1. `Mut.Worker.Persistent` skeleton: start_link spawns BEAM, ready handshake, single `run_mutant` that does `:persistent_term` flip + `ExUnit.run/0`. Round-trip on demo_app.
2. ExUnit reset hooks for ETS + Application env + registered processes; verify on demo_app + a synthetic leak-detector fixture.
3. Run filter (`only_test_ids` or fallback) — full demo_app outcomes byte-identical with the existing `mix` worker.
4. Fallback in-process recompile + `:code.load_binary`. Decimal fallback bucket continues to land at 0 invalid.
5. Crash detection + retry threshold + fallback-to-mix routing.
6. `--worker-type` flag + per-project default. plug_crypto + Decimal benches at c=4 persistent vs c=4 mix; document in BENCHMARKS.

Each step is independently testable; commit per step, gate via `bin/verify` at every step. Persistent workers go from prototype to default only after step 6 lands and outcomes are byte-identical across the validation matrix.
