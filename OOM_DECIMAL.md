# Diagnostic Mission: Decimal OOM + Baseline Failure

## RESOLUTION (2026-05-04)

**Root cause: app-start dependency cycle.**

Decimal's project app is `:decimal`. Jason 1.4.4 declares `:decimal` in
its `optional_applications` list (and includes it in `applications`).
When mutalisk is added as a path-dep to Decimal, the runtime app-start
graph becomes:

    decimal -> mutalisk -> jason -> decimal   (cycle)

Erlang/OTP 28's `:application_controller` does not break the cycle even
though one edge is optional. `mix test` (which auto-starts the project's
app graph) deadlocks at `:application_controller.call/2` inside
`:application.load1/2`. From the user's perspective:

- The parent BEAM hangs indefinitely waiting for `mix test` to return.
- `Mut.ChildProcess.run` keeps the port open with no exit signal.
- Any output Mix emitted before the hang fits within the bounded
  buffer; the captured tail looks empty save the `:decimal app name
  same as one of its dependencies` warning Mix prints.
- Memory growth observed in the original report came from the user
  letting the hang run for hours; the BEAM's port queues + linked
  process state + (likely) a child compile retry loop accumulated.
  **The hang is the bug; the OOM is downstream of it.**

**Fix**: `{:jason, "~> 1.4", runtime: false}` in mutalisk's mix.exs.
This removes `:jason` from `mutalisk.app`'s `applications` list while
keeping the Jason modules loaded. Mutalisk only uses Jason via plain
function calls, so it does not need `:jason` to be a started OTP
application. The cycle is broken at the `mutalisk -> jason` runtime
edge.

**Phase 0 observability hooks** that were landed first remain useful
for any future bench failure:

- `Mut.ChildProcess.run` accepts `:log_path` and streams chunks to disk.
- `mix mut --keep-work-copy` retains both work-copies for post-mortem.
- `Mut.MemoryWatchdog` writes BEAM memory snapshots to
  `tmp/mut_memory.log` every 5s.

See commit `aae50a7` for the fix and `46e7d93` for the observability.

---

## Original mission brief



This is NOT a feature milestone. It's a focused diagnostic and fix
mission against a real-world target (Decimal) where mutalisk's bench
pipeline is currently:

1. Crashing the host with unbounded memory consumption.
2. Failing the baseline-test gate WITHOUT exposing why.
3. Auto-deleting the working copy on failure, preventing post-mortem.

Your job is to make the failure **observable**, **reproducible at small
scale**, and then **fix**. Do NOT attempt full-scale Decimal runs until
observability and memory-bounded child IO are in place. Re-OOMing the
host wastes hours.

The repository is at `/Users/lukaszsamson/claude_fun/mutalisk` with
v1, v1.5 (M15+M16) committed but soft-failed on Decimal acceptance.

# Read first

1. `BENCHMARKS.md` — current state of plug_crypto and Decimal smoke runs.
2. `bench/run.sh` — the bench harness; how it clones and patches Decimal.
3. `lib/mix/tasks/mut.ex` — the user-facing task; baseline gate is here.
4. `lib/mut/child_process.ex` (or wherever child Mix invocations live) —
   this is where the buffered-output problem almost certainly lives.
5. `lib/mut/work_copy.ex` — sandbox/work-copy lifecycle including the
   cleanup that's hiding the post-mortem.
6. The previous diagnostic agent's notes embedded in the user's message
   that prompted this mission (summarized: tests pass natively;
   mutalisk's baseline gate fails; the captured `output_tail` is the
   only artifact and shows just an `:decimal` app-name conflict
   warning; the work-copy is rm-rf'd in an after-block).

# What we DON'T know

- Why baseline `mix test` fails inside the instrumented work-copy when
  it passes natively.
- What's eating memory until OOM. Suspects: `System.cmd` output
  buffering, coverage runner per-file accumulation, stuck child
  retrying/looping, or a Mix dep cycle from the bench's overlay.
- Whether the OOM and baseline failure are the same root cause or two
  separate bugs.

# What we DO know

- Decimal's `mix test` passes natively (161 tests, 0 failures) on the
  bench branch.
- `mix mut --target decimal` fails the baseline gate.
- A warning surfaces: "the application name `:decimal` is the same as
  one of its dependencies." This is a strong hint that the bench's
  path-dep injection of mutalisk into Decimal's mix.exs creates
  a name shape Mix doesn't accept cleanly.
- 120GB host memory consumed by the parent terminal process before
  crash. Parent process = the BEAM running `mix mut`. The child mix
  invocation is separate and shouldn't appear in the parent's heap.
- Work-copy at `tmp/mut_work/<run_id>/` is deleted by an after-block
  in `Mix.Tasks.Mut`.

# Course of actions

Do these in order. Do not skip ahead. Each phase reduces risk for the
next.

## Phase 0 — Make failures observable (FIRST, no functional changes)

Goal: when the next Decimal run fails, you can see WHY.

### 0.1 Stream child stdout/stderr to a file, not just the last 80 lines

In `lib/mut/child_process.ex` (or wherever the `System.cmd` wrappers
live), add a `:log_path` opt that, when set, redirects the child's
output to that path INCREMENTALLY (e.g., write each chunk as it
arrives). Do NOT buffer the full output in memory; use `:os.cmd/1`-
style streaming OR `Port.open` with line-by-line consumption that
writes to file as it goes.

The buffered-output behavior must remain available for tests that
expect it (don't break existing callers). Keep `:capture_output: true`
as default; add `:log_path: path` as an alternative.

In `Mix.Tasks.Mut`, when the baseline gate runs, set `:log_path:
"tmp/mut_baseline.log"`. On failure, the full log persists.
On success, optionally truncate (or leave it; it's a dev artifact).

### 0.2 Make work-copy cleanup conditional

Add a CLI flag `--keep-work-copy` (or use the existing `--keep` if M14
already added it to `mix mut`). When set, the after-block in
`Mix.Tasks.Mut` SKIPS the `File.rm_rf!`. Document the flag in the
task's `@moduledoc`.

If `--keep` already exists for the e2e task but not the user-facing
task, propagate it through.

### 0.3 Add a memory watchdog (optional but recommended)

A small helper that periodically (every 5s) writes the host BEAM's
memory stats to a file:

    Process.info(self(), :memory)
    :erlang.memory()

Spawn it on `mix mut` start, kill it on exit. Output to
`tmp/mut_memory.log`. Cheap, useful for post-mortem ("memory grew from
500MB to 100GB between phase X and phase Y").

### 0.4 Verify Phase 0 lands

Run `bin/verify` after Phase 0 changes. All 8 layers must remain green.
Do NOT run anything against Decimal yet. Phase 0 is observability-only.

Commit at this point. Title: "Make bench failures observable: streaming
child IO + work-copy retention + memory watchdog".

## Phase 1 — Reproduce on a small scale

Goal: trigger the same failure WITHOUT running full Decimal. Smaller
scope = faster iteration, no OOM risk.

### 1.1 Construct a smaller target

Two options, in order of preference:

**(a) A single-test-file Decimal subset.** Clone Decimal, then patch
its `mix.exs` to set:

    test_paths: ["test"],
    test_load_filters: [
      fn file ->
        # only load one specific test file
        String.ends_with?(file, "decimal_test.exs")
      end
    ]

This makes Decimal's `mix test` run only one file. If the failure
reproduces, we have a small enough surface to debug. If it doesn't,
the issue is NOT in mutation execution — it's in compiling Decimal
at all OR running its full test suite under our overlay.

Run via:

    bench/run.sh --target decimal --selection static --keep-work-copy

NOTE: use `static` selection to remove coverage from the equation.
Coverage may be the OOM trigger; static is the simpler path.

**(b) A locally-constructed Decimal-shaped fixture.** If (a) doesn't
reproduce or you need something even smaller, hand-craft a tiny mix
project with the same SHAPE as Decimal: an app named the same as a
dep (the warning suggests this is the trigger). Add this fixture
under `test/fixtures/overlay_cases/decimal_shape/` so it joins the
overlay-edge-case test suite. Run `mix mut.test_schema` against it.

### 1.2 If the subset reproduces

You now have a small-scale repro. Move to Phase 2.

### 1.3 If the subset does NOT reproduce

The bug scales with project size or test count. This is unusual.
Likely candidates:

- Memory accumulation per child invocation that compounds (Phase 3
  fixes it).
- Specific Decimal test that breaks under instrumentation (find by
  bisecting test files).

Try increasing the subset (5 test files → 20 → 50). At which scale
does the failure appear? That's the clue.

## Phase 2 — Diagnose the baseline failure root cause

Once you have a repro, dig in. With `--keep-work-copy`, the working
copy is preserved at `tmp/mut_work/<run_id>/`.

### 2.1 Inspect the work-copy state

    cd tmp/mut_work/<run_id>
    cat mix.exs           # the overlay
    cat mix_user.exs      # decimal's original mix.exs
    ls -la lib/           # is decimal's lib copied?
    ls -la deps/          # is mutalisk listed?

Look for:
- Does the overlay's `Mutalisk.WrappedMixProject` correctly delegate
  to Decimal's project module?
- Is `mutalisk` listed in deps with the right path?
- Is there an app-name conflict (Decimal's app = `:decimal`, the
  warning hint)? If yes, why is `:decimal` in deps?

### 2.2 Run the baseline test manually inside the work-copy

    cd tmp/mut_work/<run_id>
    MIX_ENV=test MIX_BUILD_PATH=_build/mut_oracle \
      MIX_DEPS_PATH=_build/mut_oracle/deps \
      MUTALISK_ROLE=oracle \
      MUTALISK_PATH=/Users/lukaszsamson/claude_fun/mutalisk \
      mix test

Read the actual output (without mutalisk's 80-line tail). What's the
real failure? Likely candidates:

- Compile error in user code under the overlay.
- Test failure from some specific test file under instrumented compile.
- Mix dep resolution loop.
- Application start failure (Mut.Application or Decimal's own app).

### 2.3 Check the baseline log file from Phase 0

If Phase 0's `:log_path` is wired:

    cat tmp/mut_baseline.log

This is the FULL output — every line of `mix test`, not just the
tail.

### 2.4 Document what you find

In `OOM_DECIMAL.md` (or a new diagnostic-notes file), capture:

- The exact failure mode.
- Whether OOM happens, and at what phase.
- Whether the failure is overlay-related (mix.exs shape) or runtime
  (test execution under our environment).
- Whether the failure reproduces with `--selection static` (it should
  — if not, M15/M16 added a regression).

This becomes the spec for Phase 3.

## Phase 3 — Fix

Fixes are scoped by what Phase 2 reveals. Likely scope:

### 3.1 Bench-script overlay handling for app/dep name conflicts

If the warning "the application name `:decimal` is the same as one of
its dependencies" is the trigger:

In `bench/run.sh`, the path-dep injection adds mutalisk to Decimal's
deps. The injection must not duplicate Decimal's own app name or
shadow its existing deps. Likely fix: rename the working-copy app
(`Mut.Bootstrap.Overlay` may need to override `:app` in the overlay's
`project/0`) or strip Decimal-self-references from its deps list.

Start with a minimal fix: in the overlay's `project/0`, rename the
app to a unique-per-run name like `:"mutalisk_target_#{run_id}"`. If
that breaks Decimal's tests (because they reference `Application.spec(:decimal)`
or similar), back off. The overlay should preserve user-app identity
where possible.

If the conflict is a Mix-internal cycle (mutalisk → decimal → ... →
mutalisk), break it by ensuring mutalisk's `:path` dep is `runtime: false`
or is otherwise not re-evaluated by Decimal's compile. The
`only: [:test]` constraint should already handle most cases; add
`runtime: false` and test.

### 3.2 Memory-bounded child IO

If OOM is unbounded child output buffering (likely):

Replace every `System.cmd("mix", args, stderr_to_stdout: true, ...)`
with a Port-based consumer that:
- Reads stdout/stderr line-by-line.
- Optionally writes to a log file (Phase 0).
- Discards lines after writing (no in-memory accumulation).
- Returns only `{exit_status, log_path}` to caller, not full output.

Callers that NEED a small tail of output (e.g., baseline failure path)
maintain their own bounded ring buffer (last N lines, N = 200) instead
of receiving the full output binary.

Apply to: `Mut.OracleBuild`, `Mut.SchemaBuild`, `Mut.Coverage.Runner`,
`Mut.Worker.run_schema/4`, `Mut.Worker.run_fallback/4`,
`Mut.Recompile.recompile/3`, `Mix.Tasks.Mut`'s baseline gate.

After this fix, host BEAM memory should stay flat regardless of how
long children run or how much they output.

### 3.3 Coverage runner memory

If Phase 2 implicates the coverage runner:

The per-test-file mix invocation aggregates one BEAM's coverage data
into the parent's `%Mut.CoverageOracle{}`. For Decimal with 600+ tests,
the oracle's `by_line` map could be huge. Verify it's not exploding.

Cap by_line entries to file granularity (one entry per file, not per
line) if the per-line storage is the OOM driver. Trade off: per-file
coverage gives less precise selection but bounded memory.

### 3.4 Verify the fix

After each fix:

    bin/verify  # all 8 layers must stay green

Then:

    bench/run.sh --target plug_crypto --selection static
    bench/run.sh --target plug_crypto --selection coverage_with_static_fallback

Confirm plug_crypto outcomes are unchanged. Then:

    bench/run.sh --target decimal --selection static --keep-work-copy

If Decimal completes under static, try coverage:

    bench/run.sh --target decimal --selection coverage_with_static_fallback

Capture timings, scores, fanout. Document in BENCHMARKS.md.

## Phase 4 — Document and close out

Update `BENCHMARKS.md` with:

- The actual root cause (now that you know it).
- The fixes landed.
- Decimal's actual scores and timings.
- Whether v1.5 acceptance is now MET (Decimal completes within budget
  OR ≥10× fanout reduction documented).
- Any remaining limitations.

Update `PLAN.md`'s "Out of scope for v1.5" section if any of these
fixes pushed previously-deferred work into v1.5.

# What you must NOT do

- **Do NOT run `bench/run.sh --target decimal` at full scale before
  Phase 0 + Phase 1 are complete.** The host crashed at 120GB. Do not
  re-trigger.
- Do not implement parallel workers as part of this mission. If
  Decimal completes after the fixes, v1.5 ships and v1.6 is parallel.
  If Decimal doesn't complete after the fixes, that's information for
  v1.6 scoping — not a license to expand mission scope.
- Do not skip Phase 0. Observability is not optional.
- Do not delete `--keep-work-copy` artifacts mid-debugging. Inspect
  them, then clean up manually.
- Do not remove the `output_tail` behavior from existing error paths.
  Add streaming as ALTERNATIVE, not replacement.
- Do not change PLAN, SPEC, BOOTSTRAP, or HLD until the diagnosis is
  documented and the fix is locked. Then update them with what you
  learned.
- Do not re-attempt Decimal more than 3 times in a single session
  even with the safety nets. Each attempt costs ~10-30 minutes of
  iteration time. If you've tried 3 times and don't have a working
  Decimal run, stop, document the state, and surface to the
  orchestrator.

# Commit etiquette

- One commit per phase, minimum. Phase 0 = first commit (must be
  green at all 8 layers). Phase 1 = no code commit (it's
  reconnaissance); Phase 2 = no code commit (it's diagnosis); Phase 3
  = at least one fix commit per identified issue.
- After every fix commit, run `bin/verify`. The 8 layers must stay
  green.
- Phase 4's documentation update is its own commit.

# Final report

When you're done (or stuck), state in <500 words:

- Phase 0 outcome: are the observability hooks landed and green?
- Phase 1 outcome: was the failure reproducible at small scale? On what?
- Phase 2 root cause: what was actually wrong? Was it overlay,
  child-IO, coverage, app-name conflict, or something else?
- Phase 3 fixes: list each fix with one-sentence rationale.
- Phase 4 outcome on Decimal:
  - Did it complete under `--selection static`? If yes, time + score.
  - Did it complete under `--selection coverage_with_static_fallback`?
    If yes, time + score + fanout reduction.
  - If it didn't complete: what's the next bottleneck?
- Memory observation: peak host BEAM memory during the Decimal run.
- v1.5 acceptance status: now MET, or still soft-failed?
- Anything in PLAN, SPEC, HLD that needs updating based on findings.
- Anything the orchestrator should know about future targets — what
  shapes of mix.exs are now supported, what's still fragile.

State results. Do not narrate.

# Practical safety notes

- The fixture in `test/fixtures/demo_app` is the canonical safe target.
  Use it for all mid-development sanity checks. Do not run Decimal
  for "did my last change work" — use plug_crypto or demo_app.
- Memory watchdog log is your friend. If memory crosses 5GB, KILL the
  run immediately (`ctrl-c`). Don't wait for it to crash.
- macOS Activity Monitor (or `top -o mem`) is your second friend.
  Watch the BEAM process during Decimal runs. If it climbs past 1GB
  during baseline tests, something is wrong — kill it.
- The bench script writes to `tmp/bench/<target>/` and `tmp/mut_work/<run_id>/`.
  Both should be cleaned up on success. With `--keep-work-copy`,
  only `tmp/mut_work/<run_id>/` persists; `tmp/bench/` still cleans
  up.
- If you suspect the bench script's clone is the issue (network,
  partial clone, etc.), inspect `tmp/bench/decimal/` for completeness
  before each run. The clone shouldn't be the problem — it's
  Decimal's source unchanged — but rule it out.
- Decimal's bench branch is `mutalisk-bench` (per the agent's earlier
  note). The bench script's pinned ref is what gets cloned. If you
  modify Decimal's mix.exs to subset tests, do it in
  `tmp/bench/decimal/` after clone, before invoking `mix mut`.

# Reference

- v1 SPEC: `ELIXIR_MUTATION_TESTING_SPEC.md`
- v1.5 HLD: `ELIXIR_MUTATION_TESTING_HLD_V1_5_V2.md`
- Implementation plan: `PLAN.md`
- Benchmarks history: `BENCHMARKS.md`
- This mission: `OOM_DECIMAL.md`
- Working directory: `/Users/lukaszsamson/claude_fun/mutalisk/`

Good luck. Bring the host back from 120GB.
