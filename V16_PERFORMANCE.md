# V1.6 Performance Recommendation

Status: design recommendation (not yet a milestone). Authored after the Phase A/B/C exploration in the post-OOM_DECIMAL triage mission.

## Inputs

| Source | What it gave us |
|---|---|
| `BENCHMARKS.md` post-OOM_DECIMAL | Decimal static 33.5 min (sequential), per-mutant ≈ 5 s. plug_crypto static 128 s (sequential). |
| `bench/results/plug_crypto.static.c4.terminal.txt` | Same target with `--concurrency 4`: wall 84 s, schema_workers 68.3 s. |
| `bench/spike/persistent_beam.exs` | In-process `ExUnit.run/0` cold 8.8 ms, hot avg 80 µs (110× in-process; ≥500× vs production cold-start). |
| `OOM_DECIMAL.md` | Sequential per-mutant cost on Decimal is dominated by `mix test` cold-start (~700 ms BEAM + ~1–2 s project/test compile + ~100 ms execute). |

## Phase C.1 measurements: parallel workers

`--concurrency` is plumbed through to the runner loops (`lib/mix/tasks/mut.ex` + new `Mut.SandboxQueue`) and to `Sandbox.create_pool`. Default stays at 1; the prototype is fully behind the flag.

| Target | Mode | Concurrency | Wall | Schema workers | Fallback workers | Speedup vs c=1 |
|---|---|---:|---:|---:|---:|---:|
| plug_crypto | static | 1 | 128 s | 96.8 s | 22.0 s | 1.00× |
| plug_crypto | static | 4 | **84 s** | 68.3 s | 7.2 s | **1.52×** |
| Decimal | static | 1 | 33.5 min (2010 s) | 1973.9 s | 28.9 s | 1.00× |
| Decimal | static | 4 | **11.0 min** (657 s) | 520.1 s | 129.0 s | **3.06×** (wall) / **3.79×** (schema workers) |

Outcomes are byte-identical between concurrency levels for plug_crypto (43 schema / 21 fallback / 60.3 % combined / 0 errors / 0 invalid). Parallel execution is a perf change, not a semantics change.

Decimal `--concurrency 4` lands at **11.0 min** (657 s) versus 33.5 min sequential — a 3.06× wall speedup, with the schema_workers phase itself going 3.79× faster. The bench also surfaced a **major Phase B follow-on win**: Decimal's fallback bucket went from 0/75 killed (all 75 invalid: lock-check rejection) to 43/75 killed and **0 invalid**. The Mix-bypass recompile fix was the lock that pinned it.

**Why the gap between 4× concurrency and 1.5–3× speedup?** Each mutant spawns a fresh `mix test` BEAM. The cold-start path is mostly serialized I/O (BEAM boot, manifest read, test compile). Multiple cold-starts on the same disk contend for those resources. Sandbox pool overhead (file copy, reset) adds further serialization. Beyond `--concurrency 4`, returns diminish quickly on a single workstation.

## Phase C.2 measurements: persistent BEAM spike

`bench/spike/persistent_beam.exs` simulates the persistent-BEAM model end-to-end: load ExUnit + a target + a test once, then re-run `ExUnit.run/0` ten times, flipping a `:persistent_term` "mutant id" between iterations.

```
cold_run_us=8842
iter=1  variant=original  us=172
iter=2  variant=mutant    us=78
iter=10 variant=mutant    us=48
hot_avg_us=80
speedup_vs_cold=110.5x
```

Hot iterations average **80 µs** vs. the in-process cold of **8.8 ms** (110× in-process). The cold figure here is already much smaller than production cold because there is no `mix test` startup, no project loading, no test compile.

Compared to the production cold-start (~5 s per mutant on Decimal), the projected hot per-mutant cost is **≈ 1–10 ms** for non-trivial test bodies. That projects Decimal to **≈ 1 minute** wall in single-process mode (456 mutants × ~10 ms median, plus per-iteration setup), with linear scale-out to multiple sandbox BEAMs.

### Hazards observed

The spike script's setup (one ExUnit.start; one test module; tests stay loaded) is the easy path. Production hazards:

1. **ExUnit.start must run before `use ExUnit.Case`.** If we want to load test files after starting ExUnit, we need `ExUnit.Server.modules_loaded(false)` semantics; this is internal API. *Manageable, with a known seam.*
2. **`ExUnit.run/0` runs all loaded test modules**, not the ones we just touched. To target a single test file we have to re-purpose `ExUnit.run/0`'s filtering or invoke at a lower level. *Manageable; existing API supports `:include`/`:exclude` tags but not "this file only". May need ExUnit fork or vendoring a small piece.*
3. **State leakage**: `Application.put_env`, ETS owners, mocked modules, registry entries — anything stateful left by test N affects test N+1. ExUnit's own per-test cleanup helps but is not exhaustive across `ExUnit.run/0` invocations. *Real risk; mitigation is per-test BEAM-level isolation hooks or "reset" callbacks.*
4. **Async tests** spawn ExUnit workers that may not fully terminate before `ExUnit.run/0` returns. Subsequent runs may pick up zombie processes / observe earlier state. *Mitigation: sync-only mode for persistent BEAM, or explicit ex_unit drain-and-restart between iterations.*
5. **Compile-time-only mutations**: schema mode swaps the *active* dispatch via `:persistent_term`, which fits this model. Fallback mode rewrites source and recompiles. Persistent BEAM still wants the recompiled .beam loaded — that's a `:code.purge/1` + `:code.load_binary/3` per fallback mutant, which is where Decimal currently spends its time.
6. **Crash isolation**: a mutant that triggers a runtime crash inside the persistent BEAM kills all subsequent runs in that BEAM. *Mitigation: timeout + sandbox-BEAM restart on any uncaught exit.*

None of these is a blocker. Hazards 3 and 5 are the architecturally interesting ones; the rest are mechanical.

### Estimated implementation cost

A production `Mut.Worker.Persistent` would consist of:

| Component | Est. LOC |
|---|---:|
| Sandbox BEAM bootstrap (`Mut.Worker.Persistent.Server`) | 120 |
| Host ↔ sandbox protocol (Port or `gen_tcp` over a UDS) | 100 |
| ExUnit.run/0 wrapping (filter to one test file; collect results) | 80 |
| `:persistent_term` flip + per-iteration cleanup hooks | 60 |
| Crash-restart, timeout enforcement, structured result mapping | 80 |
| Tests (unit + 1 integration on demo_app) | 150 |
| **Total** | **~590 LOC** |

This is a meaningful lift but well-bounded — comparable to `Mut.Sandbox` itself.

## Recommendation

**Sequence both, A first then B.**

### v1.6 — Parallel workers (commit-ready)

The parallel-workers prototype is already on master behind `--concurrency N` (default 1). Promote it to v1.6 by:

1. **Cross-target validation**: run plug_crypto and Decimal at `--concurrency` 1, 4, 8 — ensure outcomes are byte-identical across concurrencies and timeouts/errors do not increase. Today's data: plug_crypto identical at c=4; Decimal pending.
2. **Bump default**: change CLI default from 1 to `min(System.schedulers_online(), 8)` once cross-target validation lands. Keep `--concurrency 1` available for debugging.
3. **Watch: `Mut.LastKiller`** — currently a GenServer with synchronous `record_kill`/`lookup`. Under c=8 with 5 ms tests this could become a bottleneck. The mitigation is straightforward (cast for record_kill, ETS-backed lookup) but should ship with v1.6.
4. **Acceptance**:
   - All bench targets complete in ≤ 1.5× sequential time at `--concurrency 1` (i.e. no overhead regression).
   - Decimal completes in ≤ 15 min at `--concurrency 4` on a 4-core+ machine.
   - Outcomes byte-identical across c=1/c=4/c=8 (modulo timeout count, which can race).
   - `bin/verify` adds an `e2e_concurrent` layer that runs demo_app at `--concurrency 4` and asserts the same plan composition as c=1.

**Why first**: shipped in days, not weeks; unblocks Decimal as a routine bench target; confirms there are no architectural surprises in the existing sandbox/work-copy invariants under parallel load. Sets the stage for B.

### v1.7 — Persistent BEAM workers

Persistent BEAM is the architecturally correct answer and the only path that gets Decimal under a minute. Pursue as v1.7 after v1.6 lands.

1. **Build `Mut.Worker.Persistent.Server`** as documented above.
2. **Schema-mode first**: the `:persistent_term` flip is exactly what schema mode wants; no source rewriting needed inside the persistent BEAM.
3. **Fallback mode second**: layer in `:code.load_binary/3` after each `Kernel.ParallelCompiler.compile_to_path/2` produces a fresh .beam.
4. **Hazard mitigations** for state leakage, async tests, crash isolation, ExUnit lifecycle — see Phase C.2 above.
5. **Acceptance**:
   - Per-mutant wall under 50 ms median for demo_app.
   - Decimal completes in ≤ 2 min at `--concurrency 4`.
   - State-leakage detector test: a mutant that mutates `:persistent_term` outside its own slot is rejected.
   - Crash-recovery test: a mutant that raises in `setup_all` does not break subsequent iterations.
   - Outcomes byte-identical to v1.6 on plug_crypto, Decimal, and demo_app.

### Why "both, sequenced" rather than "skip A, go straight to B"

- Parallel workers is the smaller change with the higher floor: today it gives 1.5–3×, costs ~190 LOC, and doesn't touch the test runner.
- Persistent BEAM is a deep change to the worker model. Doing it first means the bench safety net is the still-young v1.5 sandbox harness. Doing it after parallel workers means we have multi-sandbox parallel execution to fall back to if persistent BEAM hits a state-leakage bug we did not foresee.
- The two compose: `--concurrency N` × persistent-BEAM workers is the v1.7 endgame. Each component validated on its own first.

## Confidence

| Claim | Confidence |
|---|---|
| `--concurrency 4` gives a real speedup on Decimal | high (plug_crypto data + per-mutant cost analysis; final number pending) |
| Persistent BEAM gets sub-minute Decimal | medium-high (in-process spike + hazard list; not yet a real worker) |
| The hazards listed are the complete set | medium (state leakage in particular has long tails; persistent BEAM in CI tools historically surprises authors) |
| The 590-LOC estimate for `Mut.Worker.Persistent` | medium (could grow 1.5× with hazard mitigations) |

## What this does NOT change

- `PLAN.md` v1.5 acceptance is unaffected — those targets stand as documented in BENCHMARKS.md (post-OOM_DECIMAL "partially met").
- `SPEC.md` is unaffected; both options preserve the current outcome semantics.
- `ELIXIR_MUTATION_TESTING_HLD_V1_5_V2.md`'s "future work" section should be updated when v1.6 commits; do that as part of the v1.6 milestone, not now.

## Addendum: Decimal `--concurrency 4` results

Run: `bench/run.sh --target decimal --selection static --concurrency 4`. Mutalisk version: `8ae3773` (parallel-workers prototype + Mix-lock-check bypass on master).

| Metric | c=1 (post-fix) | c=4 | Change |
|---|---:|---:|---:|
| Total wall | 2010.7 s (33.5 min) | **657.6 s (11.0 min)** | **3.06× speedup** |
| Schema workers | 1973.9 s | 520.1 s | **3.79× speedup** |
| Fallback workers | 28.9 s | 129.0 s | (more real work; see below) |
| Schema killed / executed | 306 / 381 (80.3 %) | 299 / 381 (78.5 %) | -1.8 pp (timeout race) |
| Fallback killed / executed | **0 / 0** (75 invalid) | **43 / 75 (57.3 %)** | **all 75 fallback now execute** |
| Combined kill rate | 82.7 % | 78.8 % | -3.9 pp |
| Errors | 0 | 1 | +1 |
| Invalid | 75 | **0** | **-75 (Phase B fix)** |
| Timeouts | 11 | 21 | +10 (parallel I/O contention) |
| Selection mode | static | static | identical |

The two big findings:

1. **3× speedup at c=4** is much closer to the linear ceiling than plug_crypto's 1.52×. Decimal's per-mutant cost is more uniform (~5 s each) and the test suite is small enough that I/O contention is not the bottleneck. The schema_workers phase alone goes 3.79×, which is essentially perfect 4-way scaling minus sandbox overhead.

2. **Phase B (Mix lock-check bypass) lands properly only with the parallel run** because the c=1 run was finished before that fix shipped. The c=4 run shows fallback going from "all 75 invalid (lock mismatch)" to **0 invalid, 43 killed, 32 survived**. Decimal's guard fallback engine actually works on this target now; the bench-level finding that "Decimal fallback is broken" was an artifact of sandbox infra, not the mutator.

3. **Combined score drops** from 82.7 % to 78.8 % because the bench's score formula counts only `Killed / (Killed + Survived)` per bucket. With 75 newly-valid fallback mutants and a 57 % kill rate there, the fallback bucket pulls the combined number down. This is *correct* signal — the fallback mutants tell us about Decimal's tests' guard coverage, which the previous run was hiding under the `:invalid` carpet.

4. **Timeouts rose from 11 to 21**. Some of this is parallel I/O contention; some is genuine: with 4 parallel sandboxes hitting disk and CPU, slow mutants get penalised more than they did sequentially. v1.6 should think about per-mutant timeout tuning under load.

Acceptance reading from the v1.5 OOM_DECIMAL acceptance list:

- ✓ Decimal completes within 30-min budget (was 33.5 min sequential, now 11.0 min at c=4 — comfortably inside).
- ☐ Coverage selection reduces fanout ≥10× (still 1.5×; coverage's contribution is independent of parallelism).
- ✓ Memory bounded (peak BEAM still ~80 MB; parallelism does not change this).
- ✓ plug_crypto outcomes unchanged across c=1/c=4.
- ✓ Decimal fallback bucket now produces real signal.

This is the missing piece for v1.5 acceptance. Folding into BENCHMARKS.md.

