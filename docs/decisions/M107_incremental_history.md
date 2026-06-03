# M107 — Incremental history validation (the trust gate)

**Date:** 2026-06-03

> **Superseded in part (2026-06-03 review).** The "diff-scoped correctness"
> result below — *editing one function re-executes only that function's
> mutants* — was **unsound** (Mutalisk doesn't track cross-file dependencies, so
> a mutant calling a changed helper would reuse a stale verdict). The reuse key
> now includes a coarse **project fingerprint**: any source/test-support/config/
> dependency change invalidates **all** reuse. The ground-truth and
> wall-clock results below still hold; the diff-scoped property is replaced by
> "a source change invalidates all reuse" (`bench/m107_incremental_validation.exs`
> property B). See `docs/decisions/incremental_reuse_soundness.md`.

Incremental reuse is only worth shipping if it **never changes the answer**. A
stale-reuse bug produces a wrong score that looks right — strictly worse than a
slow run. This milestone is the trust gate: prove, against real code, that a
warm `--incremental` run reproduces the full-run verdicts exactly, that a
source edit re-executes only what it must, and that the win is real.

**Verdict: the correctness properties hold; `--incremental` is sound to ship
opt-in.** Zero verdict divergence on every tree tested; diff-scoped runs match
full-run ground truth; the wall-clock win scales with mutant count (≈9.75× on
decimal). It stays **opt-in** this cycle (default flip is a future,
post-real-CI decision — Explicitly NOT v1.29).

---

## Evidence

### 1. Ground-truth correctness — full vs incremental on an unchanged tree

The verdicts of a warm `--incremental` run must equal a cold full run, mutant
for mutant, with an identical score.

| target | mutants | cold score | warm score | verdicts identical | reused / executed |
|---|--:|--:|--:|:--:|--:|
| demo_app (e2e, CI-locked) | 31 | 67.7 | 67.7 | **yes** | 31 / 0 |
| decimal (`--max-mutants 100`) | 100 | 80.0 | 80.0 | **yes** | 89 / 1¹ |

¹ decimal reused 89 of the 90 non-invalid mutants; 1 was conservatively
re-executed (its selected-test set digested slightly differently between runs)
and **still produced the same verdict** — the conservative direction working as
designed. The 10 `CompileError` (invalid) mutants are never stored and were
re-derived, as the M104 table requires.

The demo_app ground-truth check is a **permanent CI regression** in
`mix mut.e2e` (`mut.e2e incremental=reused=31 executed=0`), so this property is
re-proven on every `bin/verify`.

### 2. Diff-scoped correctness — only the edited function re-executes

`bench/m107_incremental_validation.exs` (run clean, **both properties PASS**)
makes an equal-length, semantics-preserving edit to `Arith.score`
(`a + b` → `b + a`: addition commutes, so the baseline stays green and no byte
offsets shift), then runs warm `--incremental`:

- **7 / 31 executed** — exactly `Arith.score`'s mutants (their function-level
  `source_digest` changed).
- **24 reused** — every other file's mutants *and* `Arith.integer_parts`'
  mutants (same file, unedited function): proof the scope is **function-level**,
  not whole-file.
- **off-target executed = 0** — nothing outside the edited file re-ran.
- **warm verdicts == a fresh full run on the edited tree** — diff-scoped reuse
  reproduces full-run ground truth.

This is also the **invalidation** proof for a source change: editing a function
invalidates exactly its mutants and nothing else.

### 3. Invalidation correctness — the decision logic

The reuse predicate (`Mut.History.Reuse`) is unit-tested for every invalidation
axis (`test/mut/history/reuse_test.exs`): a changed `source_digest`, a changed
`selected_tests_digest` (a survivor whose tests changed re-executes — it might
now be killed), a changed `test_timeout_ms` for timeout verdicts, a missing
entry, and the `--since` changed-file gate all yield `:execute`. Errors and
invalids are never stored, so they always re-execute.

### 4. Wall-clock win

| target | mutants | cold (full) | warm (`--incremental`, no change) | speedup |
|---|--:|--:|--:|--:|
| demo_app | 31 | 15.7 s | 9.3 s | 1.69× |
| decimal | 100 | 156 s | 16 s | **≈9.75×** |

The speedup **scales with mutant count**. demo_app is tiny, so fixed phases
(oracle build, schema build, baseline, coverage) dominate and cap the win at
1.69×. On decimal — where per-mutant test execution dominates — reuse collapses
156 s to 16 s. The residual 16 s is the fixed-overhead floor (those same phases
plus the schema build, which still instruments all mutants; see Limitations).

---

## CI-usage guide

Incremental history is built for the **small-diff CI re-run** — the common case
where a PR touches a few functions and most mutants' verdicts are unchanged.

1. **Enable it on PR builds:** `mix mut --incremental` (or `incremental: true`
   in `.mutalisk.exs` / `config :mut`). The first run is a normal full run that
   writes history; subsequent runs reuse.
2. **Persist `_build/mut_history/` across CI runs.** History lives in the user
   project's `_build/mut_history/history.json`. Cache/restore it between builds
   (e.g. a CI cache keyed on the lockfile + a coarse source hash). Without a
   restored store, every run is cold — correct, just not faster.
3. **Optionally scope to the diff:** `mix mut --incremental --since origin/main`
   forces re-execution of mutants in files changed since the ref (defense in
   depth on top of the digest check); unchanged files reuse.
4. **Trust model:** reuse is keyed on exact digest match
   (`source_digest` = the enclosing function's normalized source;
   `selected_tests_digest` = the selected tests' content). A `tool_version` or
   `format_version` change invalidates the whole store (cold). A corrupt store
   is ignored, not trusted. You can always force a clean baseline by deleting
   `_build/mut_history/`.
5. **A reused score is identical to a full-run score** — that is the property
   M107 validates. Treat `--incremental` output as authoritative for gating.

---

## Limitations / future work (not v1.29)

- **Schema build is not skipped for reused mutants.** The schema engine still
  instruments every planned mutant before the reuse pre-pass removes the reused
  ones, so the schema-build phase is not saved — only per-mutant test execution
  is. This is why decimal's warm run floors at 16 s rather than approaching
  zero. Skipping schema instrumentation for reused mutants is a future
  optimization.
- **Default `--incremental`** remains a future decision, gated on real CI
  adoption beyond this matrix (Explicitly NOT v1.29).
- **Broader matrix.** Validated on demo_app (CI) + decimal (real OSS). The full
  M91 12-target sweep is bounded by session/runtime envelope (consistent with
  the M55/M59 env-gated-matrix precedent); the two targets exercise both the
  in-repo fixture and a real dependency-bearing project, and both show zero
  verdict divergence.
