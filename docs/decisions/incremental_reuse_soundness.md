# Incremental reuse soundness — review fixes (P1a, P1b, P2)

**Date:** 2026-06-03

A review of the v1.29/v1.30 incremental-history feature found three issues. All
three are addressed here. The headline consequence: the **per-function
"diff-scoped" reuse** that v1.29 (M107) and v1.30 (M109) demonstrated was
**unsound** and has been removed in favor of a coarse, correct project
fingerprint. Reuse now follows the project's own principle —
*incorrect reuse is worse than a slow run.*

## P1a — reuse was not invalidated by dependency / config / dependency-lock changes

**Problem.** The reuse key hashed only the mutant's *enclosing function* source
(`source_digest`) and its *selected `_test.exs` files* (`selected_tests_digest`).
A change to anything else that affects the mutant's behavior slipped through:

- another `lib/*.ex` file the mutated function calls (`lib/helper.ex`),
- `test/support/*`, `test_helper.exs`, fixtures,
- `config/*.exs`,
- `mix.lock` (dependency versions).

Each could flip a verdict while both per-mutant digests still matched →
**stale reused survivors or kills**. `--since` only gated the mutant's *own*
file, not these.

**Fix.** Added `Mut.History.Digest.project_digest/1` — a coarse fingerprint over
**all** `lib/**/*.ex`, all non-`_test.exs` files under `test/` (support,
helpers, fixtures), `config/**/*.exs`, and `mix.exs`/`mix.lock`. It is recorded
on every verdict and required to match for **any** reuse. A change to any of
those invalidates the whole store.

**Consequence — diff-scoping removed.** Because the fingerprint covers all of
`lib`, editing *one* function now invalidates *every* mutant's reuse, not just
that function's. This is deliberate: Mutalisk does **not** track per-mutant
call-graph dependencies, so the previous per-function reuse (M107's "only the
edited function re-executes", M109's instrumentation pruning on a diff) was
**unsound** — a mutant in `a.ex` calling a helper in `b.ex` would reuse a stale
verdict when `b.ex` changed. The sound first version over-invalidates;
**dependency-aware fingerprints** that restore diff-scoped reuse precisely are
future work. Incremental reuse still pays off for the unchanged-tree CI re-run
(re-running a build with no source change reuses everything).

`_test.exs` files are excluded from the project fingerprint on purpose — each
mutant's *selected* tests are already digested per-mutant, and a non-selected
test file cannot affect that mutant's verdict.

## P1b — timeout-budget change ignored for non-timeout verdicts

**Problem.** `Mut.History.Reuse` only required `test_timeout_ms` equality for
stored `"timeout"` verdicts. Lowering `--test-timeout-ms` can turn a previously
`survived` mutant into a `timeout` *detection* — but it would still be reused as
`survived` if the source/test digests matched.

**Fix.** `test_timeout_ms` equality is now required for **all** reused verdicts
(killed/survived/timeout). A budget change invalidates the whole store.

## P2 — custom history path read but not written

**Problem.** `load_verdicts/2` honored `opts.history_path`, but `write_history/4`
wrote (and reloaded) only the **default** path. A user with a configured
`:history_path` read from the custom store while writing to the default one →
the custom store was never warmed (or served stale results).

**Fix.** `write_history/4` now resolves the path with
`History.Store.path(target_root, history_path: opts.history_path)` — the same
override `load_verdicts/2` uses. Read and write hit the same store.

## Validation

- `Mut.History.Reuse` reuses only when source + selected-tests + **project**
  fingerprints **and** the timeout budget all match (`reusable?/2`).
- M107 harness (`bench/m107_incremental_validation.exs`), both properties PASS:
  - **A (unchanged tree):** warm reuses all 31, verdicts identical, score 67.7.
  - **B (source-change invalidation):** a semantics-preserving edit to one file
    invalidates **all** reuse (executed 31/31, reused 0) and warm verdicts still
    equal a fresh full run — no stale verdict slips through.
- Unit tests cover: project fingerprint changes on lib/test-support/config/
  mix.lock edits and ignores `_test.exs` (`digest_test`); the timeout budget
  gates every status and the project digest gates reuse (`reuse_test`).
- `--incremental` absent ⇒ v1.28 byte-identical (demo_app 67.7, 27/4, 33).
  `bin/verify` green.

## Future work

- **Dependency-aware fingerprints** — per-mutant call-graph + per-test
  dependency tracking to restore sound diff-scoped reuse (and with it M109's
  instrumentation pruning on small diffs). Until then the project fingerprint is
  the conservative-correct gate.
- `priv/` runtime assets are not yet in the fingerprint (rare; noted).
