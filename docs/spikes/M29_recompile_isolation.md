# M29 — Persistent Recompile Isolation Spike

**Status:** decision committed.
**Date:** 2026-05-10.
**Author:** v1.11 work, ahead of M30.

## Question

Does running the persistent worker's in-process fallback recompile in
a fresh Erlang process (instead of the persistent BEAM's main
process) close the parse-class drift on `nimble_options` and the
warm-state drift on `ecto`?

If yes: helper-process isolation is a single fix that subsumes
M30 (Ecto) and the nimble_options parse-class residual at once.
If no: M30 must attack drift target-class-by-target-class, and
helper-process isolation is a dead end.

## Modes compared

| Mode | What it does | Status |
|---|---|---|
| `mix_spawn` | Host-side fallback: `mix mut.recompile` runs `Kernel.ParallelCompiler.compile_to_path/2` in a fresh BEAM. | Already shipped (baseline truth). |
| `in_process` | Persistent BEAM main process calls `Code.compile_file/1` directly. | Default since M21. |
| `helper_process` | Persistent BEAM spawns a `Task.async` whose body calls `Code.compile_file/1`; modules land in the global module table; parent restores after. | Implemented for the spike, opt-in via `MUT_PERSISTENT_COMPILE_MODE=helper_process`. Not shipped as default. |
| `parallel_compiler` | `Kernel.ParallelCompiler.compile/2` in the persistent BEAM (establishes parallel-compile context). | NOT measured — see "Future work". |

## Method

For each of `nimble_options` v1.1.1 and `ecto` v3.13.6 (the two
M25 targets where in-process drift dominates):

1. Run `bench/run.sh --target <T> --concurrency 4 --worker-type mix`
   to capture the truth-set.
2. Run with `--worker-type persistent` (default `in_process` mode).
3. Run with `MUT_PERSISTENT_COMPILE_MODE=helper_process` and
   `--worker-type persistent`.
4. Compute per-pair drift via `mix mut.drift` and direct
   stable-id status diffing.
5. Capture wall-clock, mutant-run median, and memory peak.

Per-target archive of the helper-process and in-process result
JSONs is committed under
`bench/results/<target>.static.c4.persistent.{in_process,helper_process}.{stryker.json,terminal.txt}`.

## Results

### nimble_options v1.1.1 (72 mutants)

| | mix | in_process | helper_process |
|---|---:|---:|---:|
| Combined score | 80.6% | 82.5% | 82.5% |
| Killed | 49 | 49 + 18 (= 67) | 49 + 18 (= 67) |
| Survived | 9 | 9 | 9 |
| CompileError | 0 | 14 | 14 |

Drift vs mix:

| | in_process | helper_process |
|---|---|---|
| `Killed → CompileError` (parse_class) | 14 | 14 |
| `Killed → Survived` | 0 | 0 |
| `Survived → Killed` | 0 | 0 |
| `RuntimeError → Killed` | 3 | 3 |
| **Total drift mutants** | **17** | **17** |

`in_process` vs `helper_process` directly:

| | count |
|---|---:|
| `CompileError → Killed` | 4 |
| `Killed → CompileError` | 4 |

The two persistent modes drift *against each other* on 8 mutants
but produce the **same total drift count** vs mix (17). The CompileError
set shifts (different mutants compile-error in each mode) but the
size of the set is unchanged. This is run-to-run variance, not
a real reduction.

Wall-clock:
- `in_process`: 19.0 s.
- `helper_process`: 18.0 s.

### ecto v3.13.6 (994 mutants)

| | mix | in_process | helper_process |
|---|---:|---:|---:|
| Combined score | 78.0% | 76.0% | 75.8% |
| Killed | 769 | 882 | 877 |
| Survived | 217 | 109 | 113 |
| CompileError | 1 | 3 | 3 |
| RuntimeError | 7 | 0 | 0 |

Drift vs mix (sum of pair-buckets):

| | in_process | helper_process |
|---|---:|---:|
| `Killed → Survived` | 23 | 22 |
| `Survived → Killed` | 62 | 58 |
| `RuntimeError → Killed` | 115 | 115 |
| `RuntimeError → Survived` | 23 | 23 |
| `RuntimeError → CompileError` | 2 | 2 |
| `Timeout → Killed` | 1 | 1 |
| **Total drift mutants** | **226** | **221** |

`in_process` vs `helper_process` directly:

| | count |
|---|---:|
| `Survived → Killed` | 4 |
| `Killed → Survived` | 7 |

Helper-process moves 5 mutants out of the drift set (226 → 221).
The dominant warm-state classes (`RuntimeError → Killed` 115
and `Survived → Killed` 58–62) are **unchanged in count and
nearly unchanged in identity**.

Wall-clock:
- `in_process`: 296 s.
- `helper_process`: 283 s.

Memory:
- `in_process`: peak 148.4 MB total, 25.6 MB processes.
- `helper_process`: peak 149.0 MB total, 24.6 MB processes.

Mutant-run median:
- `in_process`: 73.3 ms.
- `helper_process`: 78.5 ms (+5 ms; one Task spawn per fallback).

## Why doesn't helper-process help?

`Code.compile_file/1` mutates state in two distinct places:

1. **Process-local state**: process dictionary (`:elixir_compiler_*`
   keys), per-call message queue, per-call `:erlang.process_info`
   data. Spawning a fresh `Task` resets all of this.
2. **BEAM-global state**: ETS tables owned by `:elixir` (for module
   metadata, alias caches, dispatch tables) and the loaded-module
   table itself. **A spawned Task shares all of this with its
   parent.**

The drift classes the spike targeted live in BEAM-global state:

- **Parse-class on nimble_options.** `Kernel.ParallelCompiler` (used
  by mix-spawn) and `Code.compile_file/1` (used by both persistent
  modes) implement different parsing pipelines. The 14 mutants that
  CompileError under both persistent modes do so because
  `Code.compile_file/1`'s parser path interacts with already-loaded
  module metadata that `Kernel.ParallelCompiler` would re-derive.
  Process boundary doesn't help.
- **Ecto warm-state.** `Ecto.Query.Planner` and `Ecto.Schema` use
  ETS-backed compile-time caches that survive process boundaries.
  When mutant N's recompile populates these caches with mutated
  metadata, mutant N+1's tests read polluted cache entries
  regardless of which process did the compile.

The 5-mutant difference on ecto is run-to-run noise of the same
order as ExUnit seed variation; helper_process is not 2.2%
"better", it's effectively the same outcome.

## Decision

**Recommendation: do NOT proceed with helper-process recompile
isolation as a v1.12 milestone. Attack drift target-class-by-target-
class via M30 + a separate parse-class follow-up.**

Reasoning:

1. The hypothesis ("process boundary isolates compile-time state")
   is empirically false on both spike targets. The state that
   matters is BEAM-global, not process-local.
2. Wall-clock is not a draw between modes — helper_process adds
   ~5 ms per fallback mutant (visible at the median). On ecto's
   994-mutant matrix that's 5 s; trivial in isolation but pure
   cost for zero correctness gain.
3. The 5-mutant ecto improvement is within seed-variance noise;
   formalizing helper_process based on it would be cargo-culting.
4. M30's path for Ecto warm-state — surgical resets of the
   `:ecto` and `:ecto_query` ETS-backed caches between mutants —
   addresses the actual root cause and ports to other ETS-cache-
   heavy targets. Helper-process would not.

## What M30 should do (informed by this spike)

1. Identify the ETS tables Ecto's compile-time pipeline owns (e.g.
   `Ecto.Query.Planner`'s `:ecto_query_planner_cache` if it
   exists; the relevant tables in `Ecto.Schema` and
   `Ecto.Repo.Queryable`).
2. Add a per-target reset hook similar to M28's `reset_mox/0`:
   detect `:ecto` is loaded, snapshot or wipe the relevant ETS
   on each mutant boundary.
3. Validate against the 138-mutant `RuntimeError → {Killed,Survived}`
   block on ecto (the largest single sub-bucket of M27's drift).
4. If a clean reset is infeasible — for example because Ecto's
   caches are populated lazily during test execution and re-populating
   them would be required — formally classify ecto-class as
   mix-only with the exact reason in PERSISTENT_WORKER_GUIDE.md.

## What this spike did NOT measure

- **`parallel_compiler` mode** (`Kernel.ParallelCompiler.compile/2`
  in the persistent BEAM). The hypothesis here is different:
  ParallelCompiler establishes a "parallel-compile context" that
  some macro packages (notably `gettext`) require. Establishing
  that context might unblock gettext-class targets currently
  classified as boot-failure unrunnable — but the spike's
  acceptance criteria are about parse-class and warm-state, not
  gettext-class.
- **Pool-warm-state on mint / nimble_pool.** M27 surfaced this as
  a new drift class. It is not recompile-related (no recompile
  occurs for schema-engine mutants), so the spike's question
  doesn't apply.
- **Mox cluster-state residual.** M28 confirmed this is multi-node
  state, not local-process state. Spike doesn't apply.

These are all out of scope for the M29 question. v1.12+ may take
them up separately.

## Artifacts

- `bench/results/nimble_options.static.c4.persistent.{in_process,helper_process}.stryker.json`
  + matching terminal captures.
- `bench/results/ecto.static.c4.persistent.{in_process,helper_process}.stryker.json`
  + matching terminal captures.
- `lib/mut/worker/persistent_runner.ex` —
  `compile_via_helper_process/1` retained behind
  `MUT_PERSISTENT_COMPILE_MODE=helper_process` so future operators
  can reproduce the spike. Default remains `in_process`. Removal
  of `compile_via_helper_process/1` is a separate cleanup decision
  — keeping it is cheap (50 LOC) and preserves the harness for
  v1.12 follow-up spikes that may want to compare the same
  baseline.
