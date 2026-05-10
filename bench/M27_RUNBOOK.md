# M27 OSS Validation Harness Expansion — Runbook

This runbook covers the v1.11 OSS targets added in M27. SHAs are
pinned in `bench/run.sh`. All commands assume `pwd` is the repo
root and `bin/verify` is green at HEAD.

The M27 expansion adds 13 candidate targets across three rounds.
**5 are runnable** (the v1.11 acceptance set); the rest are
documented as `unrunnable` with the exact failure mode so future
operators on different toolchains can revisit them without
re-pinning.

## Per-target commands

Each target runs in 2 modes (M27 does not re-run the body-literal
matrix — M25 settled it). Run sequentially on a single host:

```bash
# Pattern (substitute <T> with target name):
bench/run.sh --target <T> --concurrency 4 --worker-type mix
bench/run.sh --target <T> --concurrency 4 --worker-type persistent
```

After both modes complete:

```bash
mix mut.drift --target <T>
```

This prints the per-bucket drift table consumed by BENCHMARKS.md.

## Round 1: primary candidates

### `phoenix_html` (v4.3.0) — UNRUNNABLE

Crashes Mutalisk schema build with `Code.format_string!/2 →
SyntaxError` on source files containing strings with embedded
escaped double quotes (HTML header content). Same failure on both
worker types — Mutalisk regression in `Mut.SchemaPlacer.render/1`,
not a persistent-specific drift signal. Tracked as a v1.11
follow-up.

### `telemetry_metrics` (v1.1.0) — CLEAN

Smallest target in the M27 set. 31 mutants total (21 schema, 10
fallback). 90.3% combined score, byte-identical mix vs persistent.
Boots in <2 s; runs in ~45 s per mode.

### `mint` (v1.8.0) — DRIFT

Per-target prep: drop the IntegrationTest files (they aren't
tagged and expect a local httpbin / nghttp2.org listener):

```bash
rm -f tmp/bench/mint/test/mint/integration_test.exs
rm -f tmp/bench/mint/test/mint/http1/integration_test.exs
rm -f tmp/bench/mint/test/mint/http2/integration_test.exs
```

The harness does this automatically. Runtime: ~3 min per mode.

Drift: 49/250 mutants (19.6%) where `mix=Survived →
persistent=Killed`, all in `lib/mint/http2.ex`,
`lib/mint/core/transport/ssl.ex`, and `lib/mint/http1.ex`. Auto-
classified as `:pool_warm_state`. NEW unsupported pattern beyond
M25's four; documented in PERSISTENT_WORKER_GUIDE.md.

### `finch` (v0.9.1) — UNRUNNABLE

Transitively depends on `:x509`, which fails to compile on
Erlang/OTP 28 with:

```
no record AttributePKCS-10 found at .../public_key-1.20.1/include/PKCS-FRAME.hrl
```

Pin remains in the harness for future operators on OTP 27 or with
a patched x509 release.

### `ex_machina` (v2.8.0) — UNRUNNABLE

Lists `:credo` as a dev/test dep. Credo's `ConfigCommentFinder`
regex is rejected by Elixir 1.19's stricter character-class
parser:

```
** (Regex.CompileError) invalid range in character class at position 16
```

ex_machina at v2.8.0 has no path to drop the credo dependency
without forking; classified as unrunnable on Elixir 1.19+.

## Round 2: secondary expansion

### `plug` (v1.19.1) — UNRUNNABLE (Mutalisk SchemaPlacer)

Same SchemaPlacer escaped-quote crash as `phoenix_html`. Per-target
prep drops `test/plug/ssl_test.exs` (3 baseline failures from
work-copy cwd resolving fake keyfile paths differently); the
schema build crash is independent of that drop.

### `nimble_pool` (v1.1.0) — DRIFT

28 mutants, 4/28 drift (14.3%) all `pool_warm_state`. Same
direction as mint. ~30 s per mode.

### `nimble_csv` (v1.3.0) — INFORMATIONAL

0 mutants surfaced — defmacro-heavy parser with little body code.
Bench completes but produces no signal for drift comparison.
Documented to discourage future re-pinning unless mutator catalogue
grows to cover macro definitions.

### `phoenix_pubsub` (v2.2.0) — UNRUNNABLE (Mutalisk SchemaPlacer)

Per-target prep tag-skips 2 tests with OTP 28 ETS shape drift, but
the schema build still crashes on the escaped-quote pattern.

## Round 3: tertiary candidates (pure-logic libraries)

These were selected to avoid the SchemaPlacer escaped-quote crash.

### `castore` (v1.0.9) — CLEAN

6 mutants (4 schema, 2 fallback). All survive in both modes (CA
cert handling is mostly constants and lookup). Byte-identical.
~15 s per mode.

### `mime` (v2.0.7) — CLEAN

5 mutants. 60% score in both modes. Byte-identical. ~10 s per
mode.

### `gen_stage` (v1.3.2) — INFORMATIONAL

Mix mode flaked on a single timing-dependent test in baseline.
Persistent mode ran cleanly. Classify as informational rather
than re-running until the flake is understood; not a v1.11
default-flip-blocker either way.

### `tzdata` (v1.1.3) — UNRUNNABLE

Baseline test failures (timezone data fetcher tests fail without
network). Per-target prep would need to mock the data source;
deferred to v1.12+.

## Aggregate runtime

Round 1 + 2 + 3 sequential: ~12 minutes wall on an M2 MacBook Pro
when only the 5 runnable targets are exercised. Including the
unrunnable round-trips (clone + `mix deps.get` + first compile,
which still happens before the failure surfaces): ~25 minutes.

## Re-running for v1.12+

To add a new target:

1. Pick a tag, query `git ls-remote`, pin the SHA in `bench/run.sh`.
2. Add a `case` arm in the per-target prep section if the target
   needs test exclusions / seed pinning / file deletions.
3. Document the target in this runbook, regardless of outcome.
4. `bench/run.sh --target <name> --worker-type mix` then
   `--worker-type persistent`.
5. `mix mut.drift --target <name>` to classify drift.
6. Add a row to BENCHMARKS.md's M27 table (or open a v1.12
   table after M28/M30 land).

## Re-running M27's matrix

```bash
# Five non-unrunnable targets, ~5 min wall total:
for t in telemetry_metrics mint nimble_pool castore mime; do
  bench/run.sh --target $t --concurrency 4 --worker-type mix
  bench/run.sh --target $t --concurrency 4 --worker-type persistent
done
mix mut.drift --all
```
