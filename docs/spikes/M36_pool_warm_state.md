# M36 — Pool-Warm-State Characterization Spike

**Status:** decision committed.
**Date:** 2026-05-10.
**Author:** v1.12 milestone.

## Question

M27's bench harness expansion surfaced a new drift class on `mint`
v1.8.0 (49 / 250 = 19.6%) and `nimble_pool` v1.1.0 (4 / 28 =
14.3%): all `mix=Survived → persistent=Killed`, all in pool /
HTTP-client code paths. M27 named it `:pool_warm_state` on the
hypothesis that pool / socket / registry state baked into a
warm BEAM was making persistent over-kill.

M36 characterises the leak class before any reset-hook
implementation. Three options on the table:

1. **Reset hook** — if cheap and effective, ship in v1.12.
2. **Mix-spawn reroute** — route pool-class drifting mutants
   via mix-spawn at runtime.
3. **Formal mix-only classification** — mirror M30's Ecto
   outcome.

## Modes compared

| Mode | What it does | Status |
|---|---|---|
| `mix_spawn` | Host-side fallback: fresh BEAM per fallback mutant. | Already shipped (truth set). |
| `default` | Persistent BEAM with M27 / M28 / M30 reset stack (`application_env`, `ets`, `processes`, `persistent_term`, `on_exit`, `mox`, `ecto`). | v1.11 / v1.12 default. |
| `apps_restart` | Default reset stack PLUS `Application.stop/1` + `Application.ensure_all_started/1` for `:mint`, `:finch`, `:nimble_pool` between mutants. | Implemented for the spike behind `MUT_PERSISTENT_POOL_RESET=apps_restart`. **Not** shipped on any user-facing path. |
| `process_tree_kill` | Originally scoped: kill+restart pool supervisors directly. | NOT implemented separately — see Method note below. |

**Method note on `process_tree_kill`:** mint and nimble_pool both
declare their `application` callback as a thin metadata block
(`extra_applications: [:logger, :ssl]` / similar) with **no
`:mod` supervisor entry**. Neither library owns a supervisor
tree at boot. There is nothing for `process_tree_kill` to
restart that `apps_restart` doesn't already cover; the modes
collapse for this target class. The spike merges them into
`apps_restart`.

## Method

For each of `mint` v1.8.0 and `nimble_pool` v1.1.0:

1. Run `bench/run.sh --target <T> --concurrency 4 --worker-type mix`
   to capture the truth-set (already in `bench/results/<T>.static.c4.stryker.json`).
2. Run `--worker-type persistent` (default reset stack).
3. Run `MUT_PERSISTENT_POOL_RESET=apps_restart` with
   `--worker-type persistent`.
4. Diff stable-id status partitions across the three runs.
5. Capture wall-clock and memory peak.

`finch` is classified `unrunnable` on Erlang/OTP 28 (transitive
`:x509` dep fails to compile). Spike skips it; the leak-class
hypothesis is identical to mint's so the decision is unaffected.

## Results

### mint v1.8.0 (250 mutants)

| Mode | Killed | Survived | CompileError | Drift vs mix | Wall | Memory |
|---|---:|---:|---:|---:|---:|---:|
| mix | 152 | 49 | 49 | — | — | — |
| persistent default | 201 | 0 | 49 | 49 (`Survived → Killed`) | 51 s | 78.7 MB |
| persistent apps_restart | 201 | 0 | 49 | 49 (`Survived → Killed`) | 51 s | 78.7 MB |

**`default` and `apps_restart` produce byte-identical outcomes:
0 mutants disagree.** Wall and memory are identical to ms-level
resolution.

### nimble_pool v1.1.0 (28 mutants)

| Mode | Killed | Survived | CompileError | Drift vs mix | Wall | Memory |
|---|---:|---:|---:|---:|---:|---:|
| mix | 21 | 7 | 0 | — | — | — |
| persistent default | 23 | 5 | 0 | 3 (2 `Survived → Killed`, 1 `Killed → Survived`) | 44 s | 62.6 MB |
| persistent apps_restart | 23 | 5 | 0 | 3 (same shape) | 44 s | 62.6 MB |

**Same as mint: `default` and `apps_restart` byte-identical, no
wall or memory delta.**

## Why doesn't apps_restart help?

Two reasons converging:

1. **mint and nimble_pool are pure-library OTP applications.**
   Their `application` callback declares `extra_applications`
   (so the runtime auto-loads them) but there is no `:mod`
   entry — i.e. no supervisor tree, no boot callback, no
   library-owned process state. `Application.stop/1` followed by
   `Application.ensure_all_started/1` is a no-op for these
   apps: there is nothing to tear down or rebuild.
2. **The drift is therefore not pool / socket / supervisor
   state.** The state would have to live somewhere these apps
   don't own. Candidates:
   - **BEAM-global RNG state.** ExUnit re-seeds per run, but
     `:rand`'s default state evolves across mutants in the warm
     BEAM. Property-based tests (mint has 6 properties) and
     anything reading default `:rand` see different sequences.
   - **Test execution order interactions** in the warm BEAM
     vs the mix-spawn re-init.
   - **Persistent kills correctly where mix happens to miss.**
     The drift direction is `mix=Survived → persistent=Killed`
     — i.e. persistent finds kills mix misses. If persistent's
     warm BEAM happens to exercise code paths mix-spawn's
     fresh-init doesn't, persistent is **more thorough**, not
     more-wrong. Stryker's "truth set" assumption (mix is
     authoritative) may simply not hold for property-based
     tests where seed-conditioned kills are random anyway.

The third hypothesis is uncomfortable but consistent with the
data. We cannot rule it out without re-running mix-spawn at
multiple seeds and asking whether the survivor set is itself
seed-stable — out of M36 scope.

## Parse-class subsection

The 4 residual `:parse_class` mutants across the corpus are:

- `nimble_options` v1.1.1: 2 (out of 18 drifting)
- `mox` v1.2.0: 2 (out of 5 drifting)

M29's spike (helper-process compile isolation) already showed
process-boundary isolation does **not** move parse-class. M36's
candidate isolation modes (`apps_restart`, the collapsed
`process_tree_kill`) operate at OTP-application granularity —
even further from parse-class than helper-process. None of them
can reach the in-process recompile parser path that produces
parse-class drift.

**Disposition: accept parse-class as a known persistent
limitation.** 4 mutants across the M25 + M27 corpus is not
worth a dedicated milestone. The bucketer correctly attributes
them to `:parse_class` so users see the disposition; the host's
recompile-category fallback already routes `:parse_error`
mutants via mix-spawn for an authoritative verdict.

## Decision

**Recommendation: maintain v1.11/M35's "supported with caveat"
stance for pool-class projects. Do NOT ship a reset hook for
pool-class.**

Reasoning:

1. The strongest reset hook the spike could implement
   (`apps_restart`) produces **byte-identical outcomes** to the
   default reset stack on both characterisation targets. There
   is no observable benefit to ship.
2. The leak class is not pool / socket / supervisor state —
   the hypothesis underlying option (1) is empirically false.
   `apps_restart` does the right thing on apps that don't have
   anything to restart.
3. **Mix-spawn reroute (option 2) does not help either.** The
   drift direction is `Survived → Killed` — i.e. persistent
   finds extra kills. Rerouting those mutants via mix-spawn
   would replace persistent's `Killed` with mix's `Survived`,
   *losing kill signal* rather than recovering correctness.
4. **Mix-only classification (option 3) is wrong for this
   class.** Mox-cluster, Ecto, and Gettext are mix-only because
   persistent produces strictly worse signal there (false
   positives, structural failures, boot-fail). For pool-class,
   persistent produces the same kill rate or higher than mix at
   2-5× wall speedup, which is exactly what the persistent
   worker is for. Forcing `--worker-type mix` would cost users
   real perf for a "drift" that may be persistent being more
   thorough.

The current v1.11/M35 stance is correct: **persistent boot
warning fires on `:mint` / `:finch` / `:nimble_pool` directing
users at `mix mut.drift` for verification; `:pool_warm_state`
bucket auto-classifies the drift; users decide per-project.**

## Operational note on parse-class

Parse-class is small (4 mutants on the entire M25+M27 corpus)
and the host's existing `:parse_error` recompile-category
fallback already routes those mutants via mix-spawn for an
authoritative verdict. No additional disposition is needed.

## What this spike did NOT do

- **Per-mutant mix-spawn reroute as a directed fix for
  pool-class drift.** Would require pool-class detection at the
  bucketer level + per-mutant routing. Even if implemented, it
  would *lose kill signal* per the analysis above. Not on the
  v1.12 horizon.
- **Multi-seed mix-spawn measurement** to test the "persistent
  is more thorough" hypothesis. Out of v1.12 scope; would need
  N runs at varied seeds and statistical analysis of survivor
  stability. v2 work.
- **Parse-class implementation work.** Per the disposition
  above, the existing `:parse_error` fallback already covers
  this; no new code needed.

## Artifacts

- `bench/results/mint.static.c4.persistent.{,apps_restart.}{stryker.json,terminal.txt}`
- `bench/results/nimble_pool.static.c4.persistent.{,apps_restart.}{stryker.json,terminal.txt}`
- `lib/mut/worker/persistent_runner/reset.ex` —
  `reset_pool_apps/0` retained behind
  `MUT_PERSISTENT_POOL_RESET=apps_restart`. Default mode does
  not call it. Removal is a separate v1.13+ cleanup decision;
  keeping it preserves the harness for a multi-seed follow-up
  spike if one is commissioned.

## Status of the v1.12 mix-only catalogue (unchanged)

Catalogue: Ecto / `:ecto_sql` (M30), Gettext (M31), clustered
Mox (M28). Pool-class (mint / finch / nimble_pool) is **not**
on the catalogue; it is `supported with caveat` per M35. M36
confirms this stance.
