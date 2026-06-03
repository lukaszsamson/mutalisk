# M109 — Incremental floor: skip schema-build instrumentation for reused mutants

**Date:** 2026-06-03

v1.29 ran the `--incremental` reuse partition *after* schema build, so the
schema engine instrumented every planned mutant — including the ones reuse
would never execute. M109 moves the reuse determination **before**
instrumentation: under `--incremental`, the plan that drives
`Mut.SchemaBuild.instrument_files/1` is the to-execute subset; reused mutants
are pruned from it (their verdicts come from history and still appear in the
report/score). Non-incremental runs prune nothing and are byte-identical to
v1.29.

## What changed

- The reuse partition + reused-verdict recording moved from `execute_plan`
  (post-schema) to `run_pipeline` (`prune_reused_for_incremental/7`,
  pre-schema). It builds a selection context against the **oracle work copy**
  (byte-identical source to the schema copy, so digests match exactly),
  partitions the plan, records the reused verdicts into the ledger, and hands
  `execute_plan` the to-execute subset.
- `execute_plan` reverted to its pre-M106 shape: run and render
  `schema_result.plan` directly. The report is built from the **ledger** (which
  carries the reused verdicts), so it is complete regardless of what the plan
  passed to schema build contained.

## Correctness (the gate)

The M107 trust-gate harness (`bench/m107_incremental_validation.exs`) passes
**both** properties with the reduced instrumentation:

- **Ground-truth** (unchanged tree): warm verdicts identical to a cold full
  run, score 67.7 == 67.7, executed 0.
- **Diff-scoped**: editing one function re-executes exactly its 7 mutants,
  reuses 24, and warm verdicts == a fresh full run on the edited tree.

On decimal (`--max-mutants 100`): warm `--incremental` reused 89/90, **verdicts
identical** to cold, score 80.0 == 80.0. Non-incremental `bin/verify` is
byte-identical (demo_app 67.7, 27 schema / 4 fallback, 33 stable_ids).

## Measured effect — and an honest finding

**Instrumentation count drops to executed-mutants-only** (the acceptance): a
warm run that reuses everything instruments **0** mutants; a small-diff re-run
instruments only the changed functions' mutants.

But the **wall-clock benefit is modest**, because instrumentation *placement*
is not the schema-build bottleneck — the **`mix compile` of the work copy is**:

| decimal (cap 100) | schema build | total |
|---|--:|--:|
| cold (full — instruments ~90) | 2974 ms | 148.0 s |
| warm `--incremental` (M109 — instruments ~11) | 2913 ms | 15.3 s |

The schema-build time barely moved (2974 → 2913 ms) despite instrumenting ~8×
fewer mutants — confirming the SchemaPlacer placement is a ~60 ms sliver of a
~2900 ms phase dominated by compiling the work copy. The 148 s → 15.3 s total
drop is overwhelmingly the **execution** savings (skipping 89 mutants' test
runs), which M106 already delivered; M109's *additional* contribution over the
v1.29 warm run (~16 s) is the ~60 ms placement saving plus marginally cheaper
compilation of fewer instrumented files.

**The residual floor is compile + fixed phases, not instrumentation.** Each run
still pays: oracle build, baseline tests, coverage collection, and the
work-copy `mix compile`. Those — not schema gate placement — are what a warm
incremental run cannot currently skip.

## Out of scope / next lever (future, not v1.30)

The real floor reduction would be **avoiding the schema-build compile** for
reused-only or small-diff runs — e.g. caching the compiled work copy across
runs, or skipping schema build entirely when the executable subset has no
schema mutants. That touches the build/work-copy lifecycle (and the report's
source loading), is a distinct optimization from "prune instrumentation," and
is deferred. M109 delivers exactly its scope: reused mutants are no longer
instrumented, with verdicts provably unchanged.

## Acceptance

- [x] Instrumentation count drops to executed-mutants-only under `--incremental`
      (measured: ~90 → ~11 on decimal; 31 → 0 on demo_app all-reused).
- [x] Per-mutant verdicts + score identical to a v1.29 incremental run
      (M107 harness + decimal + demo_app).
- [x] Non-incremental run byte-identical to v1.29.
- [x] Additional speedup documented (modest; the floor is compile-bound — see
      above).
- [x] `bin/verify` green; dialyzer clean.
