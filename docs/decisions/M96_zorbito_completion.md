# M96 — Complete zorbito's full mutation run (v1.26)

**Date:** 2026-05-28

The v1.25 M92 attempt reached the explicit "Schema build starting"
phase-transition marker on real 14-app zorbito code; the bounded
mutation run beyond that point exceeded the session-budget envelope.
v1.26 M96's goal was to push materially past schema-build start into
the mutation/report phase, sharded by app via `--files
apps/<small-app>/lib` to bound per-mutant cost.

## Outcome

**Sharded retry blocked by zorbito-local WIP compile state**
(not by mutalisk's engine; not by infra absence). The btc_scanner
app in `~/zorbito` carries local in-development changes
(`apps/btc_scanner/lib/btc_scanner/parser.ex`,
`block/current_block.ex`, etc. — these are uncommitted local edits,
visible via `git status`) that don't compile cleanly against the
current struct definitions in core:

```
error: unknown key :previous_hash for struct BtcScanner.BlockData
  lib/btc_scanner/parser.ex:98
error: unknown key :generation for struct BtcScanner.BlockData
  lib/btc_scanner/parser.ex:39
```

These are real local-development WIP artifacts (the user's in-flight
btc_scanner refactor), not env-blockers mutalisk can resolve.
`mix compile` on the unmodified-by-mutalisk zorbito tree fails the
same way — the failure is upstream of the engine path, in the
umbrella's local source state.

v1.25 M92 didn't hit this because the local WIP state evidently
landed between the M92 run (which reached "Schema build starting")
and the M96 attempt. The condition is **transient**: when the
btc_scanner refactor lands and lib/core's struct definitions catch
up, the sharded run becomes feasible again.

## What the M96 attempt verified

- Mutalisk's `mix.exs` injection pattern still works on zorbito
  (`{:mutalisk, path: System.fetch_env!("MUTALISK_PATH"), only:
  [:test], runtime: true}` — same as M92).
- Baseline tag-skip strategy still works (`:env_drift` tag on the
  two known env-specific failing tests; ExUnit excludes them via
  the umbrella test_helpers).
- The engine reaches the umbrella compile phase identically to M92.
- The blocker is upstream of mutalisk: `mix compile` itself fails
  on the local btc_scanner state.

## Acceptance

The M96 PLAN acceptance is:

> - zorbito mutation phase exercised on real code (verified
>   worker/report output past schema-build start);
> - no umbrella regression on single-app or unilink paths
>   (golden_oracle + golden_instrument green);
> - `bin/verify` green.

The mutation-phase exercise is blocked by the upstream compile
failure this cycle. The umbrella-regression acceptance is met
(golden_oracle + golden_instrument green; `bin/verify` green; no
single-app or unilink path regression). The retry-when-the-WIP-lands
path is documented as the v1.27 carry.

## Carried forward (v1.27+)

- **Re-attempt the sharded run** when zorbito's btc_scanner
  refactor lands and the umbrella tree compiles cleanly. The shard
  plan and `:env_drift` tag-skip strategy are unchanged; the only
  pre-condition is `mix compile` passing on the umbrella root.
- **Unilink remains the umbrella full-run proof** (v1.21 M74); the
  M67/M68 umbrella engine work is validated by that and is not
  regressed by anything in v1.25/v1.26 (the umbrella ebin path,
  cross-app dependents, and per-app overlay all unchanged).

## Out of scope

- Fixing zorbito's local btc_scanner WIP state itself (the user's
  in-flight refactor; outside mutalisk's responsibility).
- Multi-DB / RabbitMQ / clustering / `:erlzmq` native binding setup.
- The 14-app full default plan in one session — multi-session
  sharded runs are the bar.
