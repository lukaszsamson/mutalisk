# M74 — umbrella validation: unilink full run + zorbito (v1.21)

**Date:** 2026-05-26

Closes the v1.20 caveat (umbrella worker/report was proven only on a
synthetic 2-app umbrella) and scale-proves on 14 apps. No engine code
changes were needed — the v1.20 (M67/M68) + M71 worker fixes held up on
real multi-app code.

## unilink — real full `mix mut` (5 apps, local Postgres + RabbitMQ)

A complete `mix mut` run (oracle → schema → workers → fallback → report)
on `~/unilink` with its real test infra (Postgres `afi_test` migrated,
RabbitMQ up). Bounded with `--max-mutants 25 --selection static` to fit a
session; every pipeline phase ran:

| | |
|---|---|
| baseline tests | **passed** (full umbrella suite, real DB + RabbitMQ) |
| oracle | per-app sites across all 5 apps |
| schema build | instrumented umbrella compiled |
| workers | mutants executed against the live DB sandbox |
| fallback | **2/10 killed** — cross-app fallback recompile ran in the live run |
| report | valid multi-app: 18 files across **all 5 apps** (backoffice/unilink/unilink_backend/unilink_background/unilink_tracking) |
| score | 5/24 = 20.8% (Killed 5, Survived 19, **Invalid 1, Errors 0, Timeouts 0**) |

**0 errors** is the headline: the M71 per-app `suite_finished` aggregation
and cross-app fallback hold on real code. The low score reflects unilink's
own test-suite weakness on the sampled mutants (a real finding about the
target), not a tool issue.

## zorbito — engine path across 14 apps (NOT a gating target)

`~/zorbito` (14 apps: core, backend, merchant_api/panel, backoffice, and
the btc/eth/erc20/tron/ln scanners + chain clients). Engine path proven:

| phase | result |
|---|---|
| oracle | **150 083 dispatch sites across all 14 apps**, app-prefixed (backoffice 48.7k, merchant_panel 43.7k, core 30.5k, … zorbito_ln_client 203) |
| plan | 1882 default-plan mutants across all 14 apps (1376 schema / 506 fallback) |
| schema build | 14-app umbrella instrumented + compiled, 1213 snapshot files, **0 invalid** |

**Full worker run blocker (documented, not gating):** zorbito's suite needs
live crypto-chain infrastructure — the btc/eth/tron/ln scanners and chain
clients require their nodes/RPC endpoints, multiple databases, and
clustering — which cannot be stood up reliably here. The engine path
(oracle + schema + cross-app plan across 14 apps) is the scale proof; the
worker/fallback/report path is already proven end-to-end on unilink above.

## Verdict

Umbrella support is validated for real multi-app projects: full pipeline on
unilink (5 apps, live infra) and engine scale on zorbito (14 apps). Single-
app path unaffected (golden_oracle + golden_instrument green). zorbito's
full worker run graduates to a gating target in a future cycle once its
chain/DB/clustering test infra is reproducible.
