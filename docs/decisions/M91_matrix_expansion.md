# M91 — Wider OSS matrix: Phoenix + LV + Bandit (v1.25)

**Date:** 2026-05-28

Three new matrix targets wired into `bench/run.sh`: the two headline
adds (the ecosystem's most-used real-world apps) and one density-picked
third addition. Each has a clean baseline (zero failures, deterministic
seed) so M93 can run the full mutalisk matrix without baseline-noise
contamination.

## Targets

### `phoenix` — `v1.8.1` (`c86dd55d`)

The framework. Density (corpus mirror inspection):

- FunctionReplace allowlist: 27 sites (`Enum.min/max/filter/reject/find/
  any?/all?` etc.). Exercises the v1.23 graduation gap.
- NegateConditional: hundreds of `if/unless` branches across the lib.
- ClauseDelete (M87): 87 `case` sites + dozens of `with`/`cond`.

Baseline: `1046 tests, 0 failures` (deterministic seed 42, `mix test`
in ~25s). Tests start `plug_cowboy` in-process; no DB or external
network needed.

Prep: strip `.tool-versions`; pin ExUnit seed.

### `phoenix_live_view` — `v1.0.2` (`f73eac3e`)

The Elixir ecosystem's densest macro-heavy DSL. Density:

- FunctionReplace allowlist: 36 sites — highest of the untried corpus.
- Large NegateConditional + Case surface; exercises M78 codegen-context
  exclusion (the `heex`/`sigil_H` machinery is exactly where false
  positives would surface).

Baseline: `1223 tests, 0 failures, 3 excluded` (env-drift tag). Tests
spin up a local `Phoenix.Endpoint`; no DB.

Prep: strip `.tool-versions`; tag-skip 3 Elixir-1.19 env-drift tests
(`html_formatter_test "does not format when empty"` — formatter output
drift; `live_view_test "live render with socket.assigns"` — KeyError
message shape drift; `elements_test "fill in calendar types"` —
calendar form serialisation drift). Mutation surface (`lib/`)
unaffected. Same pattern as ecto's regex drift and timex's microsecond
drift.

### `bandit` — `1.8.0` (`d15dd870`)

Density-picked third addition. Smaller surface than Phoenix/LV but
covers an independent codepath (Erlang `:gen_tcp`/HTTP2 / WebSocket
adapter, almost no macros). 5 FunctionReplace sites, ~ 43
NegateConditional, ~ 87 case sites.

Baseline: `653 tests, 0 failures, 1 skipped, 4 excluded`
(deterministic seed 42, ~6s).

Prep: strip `.tool-versions`; **preserve bandit's own `:slow`
exclusion** (h2spec via docker — pulls a foreign-arch image and runs
~ 15min of compliance tests, plus the WebSocket autobahn fuzzer) so
the bench run stays in-process; tag-skip one OTP-27/28 TLS test that
asserts on `ssl:connection_information(:ciphers)` (the cached-session
path drops the cipher key). Initial wiring missed the `:slow`
preservation and incurred a 15-minute h2spec docker pull; the fix
matches the regex on `exclude: :slow` so the new exclusion list keeps
`:slow` and adds `:otp_ssl_cipher_drift`.

## Targets not picked this cycle

From the 24 untried corpus members, the density measure ruled out:

- `ash`, `livebook`: very large mutation surfaces (370 / 179
  FunctionReplace sites), but commensurately heavy dep trees and
  test-time costs — defer to v1.26+ if needed.
- `kino`: needs Livebook runtime context for many tests.
- `tableau`, `quark`, `witchcraft`, `type_class`: small surfaces;
  marginal added breadth.
- `nerves_hub_*`, `wallaby`, `next-ls`, `gen_lsp`: integration-heavy
  (devices, browsers, language servers) — not in-process.
- `aino`: low-density relative to the new bandit pick (the Erlang/HTTP
  comparison value goes to bandit, more idiomatic Elixir).

## Acceptance

- 3 new matrix targets wired in `bench/run.sh` (usage banner +
  per-target REPO/REF/SHA + per-target prep block).
- Baseline runs documented and clean for all three.
- New graduation candidates (Pin / FunctionReplace / NegateConditional
  / ClauseDelete / GuardBoolean / StatementDelete) each exercised by
  ≥3 targets now achievable — M93 measures.
- `bin/verify` green (the bench wiring is a script change; the harness
  passes unchanged).

## Out of scope

- Actually running `mix mut` end-to-end on each new target — that is
  M93's responsibility (re-eval the matrix with the post-M89 hazard
  surfaces + the new M90 mutators). The wiring + clean-baseline gate
  here ensures M93 doesn't waste cycles on baseline drift triage.
- Density-picking a fourth target: 3 new + the 7-target existing matrix
  exceeds the "3-4 new" acceptance.
