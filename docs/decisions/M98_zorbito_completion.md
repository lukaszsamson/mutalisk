# M98 — Zorbito retry (contingent) (v1.27)

**Date:** 2026-06-02

The contingent zorbito retry. Two acceptable outcomes per the v1.27
scope: push past M92's "Schema build starting" marker into the
mutation phase if the btc_scanner WIP refactor landed, **or** document
the upstream block and close umbrella validation at the v1.25/v1.26
state.

## What changed since M96: the compile block is RESOLVED

The M96 blocker was a `mix compile` failure on the user's in-flight
btc_scanner refactor (`unknown key :previous_hash for struct
BtcScanner.BlockData`). **That refactor has landed** — zorbito's HEAD
is `e00aefd1b btc 30+ compat`, the tree is clean, and `MIX_ENV=test
mix compile` now succeeds across all 14 apps (btc_scanner: 33 files
compiled, struct definitions consistent). This is real progress vs
M96: the compile path is no longer a barrier.

## The remaining block: live-instance resource occupancy (environmental)

The mutation run was set up identically to M92/M96 (mutalisk injected
into `mix.exs` deps; `:env_drift` tag-skips on the two known
env-specific baseline failures; `mix mut --selection static
--max-mutants 15 --files apps/ln_scanner/lib`). It compiled the
umbrella oracle but failed at the **baseline phase**:

```
** (Mix) The database for Zorbito.Core.Repo couldn't be created:
   connection not available and request was dropped from queue after 4000ms
```

A direct `mix test apps/ln_scanner/test` (to isolate the cause) failed
differently but from the same root:

```
** (EXIT) {:listen_error, :prometheus_metrics, :eaddrinuse}
   (address already in use)
```

**Root cause: the user's live zorbito instance is running locally**
(`iex -S mix phx.server` processes were observed in the environment),
occupying the shared umbrella runtime resources:

- the **metrics/ranch ports** (`:prometheus_metrics` → `:eaddrinuse`),
  so the test/mutation run can't start the umbrella apps;
- the **DB connection pool** capacity, so mutalisk's baseline
  `Core.Repo` startup couldn't acquire a connection within the 4s
  queue window.

mutalisk requires a green baseline by design (the M13 baseline-failure
abort), and the baseline can't start the apps while the live instance
holds their ports and DB pool. This is an **environment-occupancy
block**, not a mutalisk defect, a compile issue, or missing infra:
Postgres *is* running (accepting connections on 5432) and the code
*does* compile. The only barrier is that a parallel live instance is
already using the resources.

**I did not resolve this by force.** Killing the user's running
zorbito services, or rewriting zorbito's port/DB config to dodge the
conflict, would disrupt their live environment — outside mutalisk's
responsibility and explicitly out of M98's scope ("inventing zorbito
infrastructure mutalisk doesn't control"). The principled call is to
document precisely and close.

## Outcome: close umbrella validation at the v1.25/v1.26 state

Per the M98 acceptance's second outcome, umbrella validation is closed
at the engine-proven state:

- **Engine path proven** end-to-end on real umbrella code: v1.20
  M67/M68 (single-app + cross-app fallback), v1.21 M74 (unilink real
  full `mix mut`, 5 apps, live Postgres+RabbitMQ, valid multi-app
  report), v1.21 M71 + v1.25 M92 (zorbito 14-app oracle + schema-build
  start, 150k sites, 0 invalid).
- **The btc_scanner compile block is gone** (M96 → M98 progress).
- **The only remaining barrier is environmental scheduling**: run the
  bounded mutation phase when the user's live zorbito instance is down
  (ports + DB pool free). This is a one-command retry, not a code or
  engine task.

This is a sharper close than M96: M96 left "blocked on an upstream
refactor we don't control"; M98 leaves "the refactor landed, the code
compiles, and the engine path is proven — the only thing between here
and a full zorbito mutation run is running it while the dev instance
is stopped." Umbrella validation is **complete for mutalisk's
purposes**; the remaining step is operational, not engineering.

## Acceptance

- One of the two M98 outcomes lands: the documented close-out (the
  refactor landed but the run is blocked by live-instance resource
  occupancy, precisely characterized).
- No umbrella regression on single-app or unilink paths: golden_oracle
  + golden_instrument green; `bin/verify` green.
- zorbito working tree reverted clean (mutalisk dep injection + test
  tag-skips removed).

## Carried forward (operational, not engineering)

- Run `mix mut --files apps/<app>/lib --max-mutants N` on zorbito with
  the live dev instance **stopped** — a scheduling action whenever the
  user wants the full umbrella mutation numbers. The engine, compile,
  and infra are all confirmed working; only the resource conflict
  remains.
