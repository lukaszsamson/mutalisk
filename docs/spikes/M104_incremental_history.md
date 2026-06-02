# M104 — Incremental history design spike

**Date:** 2026-06-03
**Status:** design decided; implementation is M105+ (no production code in this
milestone beyond the throwaway proof `bench/spike/m104_history_proof.exs`).

v1.29 reverses the standing incremental-history hold — the user made the
CI-adoption decision prior releases gated on. This spike fixes the consequential
design choices before any feature code, because the correctness bar is the whole
game: **a stale-reuse bug produces a wrong number that looks right — strictly
worse than a slow run.** History is opt-in (`--incremental`, M106), conservative
(reuse only on exact digest match), and validated against full-run ground truth
(M107) before it can be trusted.

The foundation already exists. `bench/cross_run.exs` (the M86 redirect) proved
the Stryker JSON report carries enough per-mutant state (stable_id + status +
duration + engine + mutator) to compute meaningful cross-run deltas with **no
engine change**. v1.29 turns that read-only prelude into a persistent,
reuse-driving feature.

---

## 1. Digest granularity — **function-level** (decided)

`source_digest` is computed **per enclosing function** (`def`/`defp` name+arity,
all clauses concatenated), not per file and not per mutated span.

| granularity | invalidation behaviour | verdict |
|---|---|---|
| **file-level** | any byte anywhere in the file invalidates *every* mutant in it | rejected — a one-line edit forces a full re-run of the file; kills the CI win |
| **span-level** (just the mutated bytes) | only the mutated token invalidates | rejected — *unsafe*: a test's verdict depends on the whole function's behaviour, not only the mutated span. Editing a guard or an earlier statement in the same function can flip a verdict while the mutated span's bytes are unchanged → stale reuse |
| **function-level** | a mutant invalidates iff its enclosing function's source changed | **chosen** — matches the unit of behaviour a test actually exercises; isolates edits to the touched function |

**Rationale.** A mutant's verdict is a property of *the mutated function's
behaviour under the selected tests*. The smallest source region that can change
that behaviour is the enclosing function clause (a sibling function changing
cannot alter this function's output for the same inputs; an earlier statement in
the *same* function can). Function-level is therefore the tightest granularity
that is still **safe** — span-level is tighter but unsound.

**Empirical proof** (`bench/spike/m104_history_proof.exs`, run clean): editing
one function's body (`* 2` → `* 4`) changes that function's digest and leaves
the sibling function's digest byte-identical, while a file-level digest changes
for both. CLAIM 1 PASS.

**Derivation.** Re-parse the file with `Code.string_to_quoted/1`, locate each
`def`/`defp` (unwrapping `when` guards), concatenate all clause sources for a
given name/arity, normalize whitespace with the **same** normalization
`Mut.StableId` already uses (`String.trim |> replace(~r/\s+/, " ")`), and
SHA-256/128 it. Normalization means pure-formatting churn (re-indentation,
trailing whitespace) does **not** invalidate — only semantic source change does.

**Non-function-scoped mutants.** Mutants outside any named function — module
attributes (`@foo`), top-level literals — have no enclosing `def`. They fall
back to a **module-level** digest (the module body's normalized source), and if
even that is ambiguous, to the **file-level** digest. This fallback is the safe
direction (coarser → more invalidation → never stale).

---

## 2. Store format + location — **JSON under the user `_build/`** (decided)

- **Format: JSON**, written through the existing `:json`/`Mut.Json` codec.
  Chosen over an ETS/`:erlang.term_to_binary` dump for inspectability (a human
  or `bench/cross_run.exs`-style tool can read it), cross-version robustness
  (term formats are fragile across OTP), and reuse of the codec already shipped
  for the Stryker reporter. The store is small (one record per mutant; even a
  large project is low-tens-of-thousands of records) so JSON parse cost is
  negligible against a mutation run.

- **Location: `_build/mut_history/history.json` in the *user project root*
  (`target_root`)**, configurable via `:history_path` (config + future flag).
  Rationale:
  - History must **persist across runs**, so it cannot live in the ephemeral
    work copy (`tmp/mut_work/<run_id>`, destroyed every run) or the throwaway
    schema/oracle build paths.
  - It must **never touch the user source tree** (Build-Path Contract).
    `_build/` is already git-ignored and is the canonical place for derived,
    disposable build state — exactly the right isolation.
  - It is the *user's* `_build/`, not mutalisk's internal `_build/mut_oracle`,
    because the history is keyed to the user's source and must survive mutalisk
    internal-build cleanup.

- **Store shape:**

  ```json
  {
    "format_version": 1,
    "tool_version": "<mutalisk version>",
    "generation": 42,
    "verdicts": {
      "<stable_id>": {
        "status": "killed|survived|timeout",
        "source_digest": "<hex16>",
        "selected_tests_digest": "<hex16>",
        "killing_test": "test/foo_test.exs",
        "killing_test_digest": "<hex16>",
        "timeout_config": { "test_timeout_ms": 10000 },
        "generation": 42
      }
    }
  }
  ```

  `format_version` and `tool_version` are the cold-start safety valve: on any
  mismatch the **entire store is ignored** (treated as no history → full run).
  Mutation semantics or store layout can change between mutalisk versions;
  reusing across a version boundary risks stale verdicts, so we don't.

---

## 3. Reuse decision table (decided — concrete per status)

For each *planned* mutant, look up its `stable_id` in the store. Reuse the
stored verdict **only** if the row's status-specific rule holds; otherwise
**execute** (the conservative default). Any missing entry, digest mismatch,
absent killing test, format/tool-version mismatch, or unrecognized status →
execute.

| stored status | reuse iff … | rationale |
|---|---|---|
| **killed** | `source_digest` unchanged **AND** `killing_test` still in the plan's selected set **AND** `killing_test_digest` unchanged | a kill is proven by *one* test; if the mutated function and that test are both unchanged, the kill still holds. We do **not** require all selected tests unchanged — an unrelated test changing cannot un-kill a mutant a specific test still kills. |
| **survived** | `source_digest` unchanged **AND** `selected_tests_digest` unchanged | a survival means *no* selected test killed it; if any selected test changed/was added/removed, a new test might now kill it → must re-execute. Requires the **full** selected set unchanged. |
| **timeout** | `source_digest` unchanged **AND** `selected_tests_digest` unchanged **AND** `timeout_config` (`test_timeout_ms`) unchanged | timeouts are timing-sensitive; reuse only when source, tests, and the timeout budget are all identical. Cautious by HLD mandate. |
| **error** | **never reuse** | errors are transient/environmental (compile flake, sandbox crash, OOM); re-execute to get a real verdict. |
| **invalid** | **never reuse** | invalid is a planning/compile artifact that can change as surrounding code changes; cheap to re-derive; never carried. |
| **skipped / no-coverage** | **not stored** | these are re-derived from the plan + coverage every run; they are not verdicts to cache. |

**Killed vs survived asymmetry is the crux.** Killed reuse keys on the *killing
test's* identity+content (narrow, sound). Survived reuse keys on the *whole
selected set's* identity+content (broad, sound) — because a survivor's status is
a statement about all selected tests, any of which changing could overturn it.

---

## 4. `selected_tests_digest` derivation (decided)

Computed from the selector output `Mut.TestSelection.select/_ ::
%{stable_id => %{test_files: [path], match_kind: kind}}`.

For a mutant's selected `test_files`:

```
selected_tests_digest =
  sha256_128(
    sort([ {relative_test_path, content_digest(test_file)} for each selected test ])
  )
```

- **Order-insensitive** (sorted) — selector ordering is a perf detail, not a
  correctness input. Proof CLAIM 2 PASS.
- **Content-sensitive** — each test file contributes its own normalized-source
  digest, so editing an assertion in a selected test invalidates the survivor
  verdicts that depend on it.
- **Selection-mode change is captured transitively.** Switching `--selection`
  from `coverage` to `static` generally changes the *selected set*, which
  changes this digest → re-execute. If the selected set is byte-for-byte
  identical under both modes for a given mutant, reuse is *correct* anyway (the
  same tests run) — so we gate on the precise selected set, not the coarse mode
  name. This is why selection mode is **not** a separate config-digest input
  (see §5).

`killing_test_digest` (for killed rows) is the single selected test's
`content_digest`, stored separately so killed reuse can check just it.

---

## 5. `config_digest` inputs — **minimized & decomposed** (decided)

The PLAN asks which config changes must invalidate. The decision, with
rationale, **refines** the HLD's coarse `config_digest` sketch:

| config knob | gates reuse? | why |
|---|---|---|
| `mutators`, `enabled_targets` | **No** | orthogonal to a given mutant's verdict. They change *plan membership* (which stable_ids exist), not the behaviour of an already-stored mutant. Enabling a new mutator adds new stable_ids; it cannot change whether mutant *X* (unchanged source, unchanged tests) is still killed. A stored verdict is reused iff its stable_id is in the new plan — absent → simply not reused. |
| `selection` mode | **No (folded into `selected_tests_digest`)** | a mode change that changes the selected set changes `selected_tests_digest` → re-execute. A mode change that yields the *same* set is safe to reuse. Gating on the precise set (§4) is both tighter and sound; a coarse mode flag would force needless re-execution. |
| `test_timeout_ms` | **Yes — timeout verdicts only** | stored as `timeout_config`. A larger timeout could turn a timeout into a kill/survival, so timeout reuse requires it unchanged. It does **not** gate killed/survived reuse (a timeout-budget change can't flip a definitive kill/survival). |
| `exclude` (file filter) | **No** | excludes change plan *membership*, not per-mutant verdicts (same as mutators). |
| `concurrency`, `reporters`, `output_path`, `max_mutants`, `keep_work_copy` | **No** | cosmetic / scheduling; provably verdict-irrelevant. |

So the effective "config digest" reduces to **`test_timeout_ms`, scoped to
timeout verdicts**. Everything else is either subsumed by `selected_tests_digest`
or orthogonal to an individual mutant's verdict. This is more correct *and* more
reuse-friendly than a monolithic config hash that would invalidate everything on
any config touch.

---

## 6. Invalidation + GC — **generation-windowed, bounded** (decided)

- **Generation counter.** The store header carries a monotonic `generation`,
  bumped each run. Every verdict written or reused this run is stamped with the
  current generation.
- **Pruning.** On write, drop any entry whose `generation < current −
  retention_generations` (default **3**). This bounds the store at roughly
  `plan_size × retention_generations` — entries for mutants that have not
  appeared in the last few runs (deleted code, removed mutators) age out.
  Default retention of 3 keeps a small grace window so a mutant that briefly
  disappears (a transiently-excluded file) can still be reused on return.
- **Version invalidation.** `format_version` mismatch or `tool_version`
  mismatch → ignore the whole store (cold start). This is the blunt safety valve
  for "mutation semantics may have changed across versions."
- **Corruption tolerance.** Unreadable/malformed store (parse error, partial
  write) → treat as no history (cold), log a warning, and overwrite on this
  run's write. History is an optimization; a broken store must never abort a run
  or, worse, be partially trusted.
- **Atomic write.** Write to `history.json.tmp` then rename, so a crash
  mid-write leaves the prior store intact (or, on first run, no store).

---

## 7. Integration points (for M105/M106 — informational)

- **Store write (M105).** End of `Mix.Tasks.Mut.execute_plan/8`, after
  `render_reports_with_timing`, the **Metrics ledger** (`snapshot.ledger`,
  entries carrying `mutant` + final `status` + `killing_test` + `covering_tests`)
  is the verdict source. Digests are computed against the **work-copy source**
  (the exact bytes the verdict was produced from). Write happens always (even
  without `--incremental`) so history accrues for the *next* run — but writing
  changes nothing observable (plan + score byte-identical), satisfying M105's
  acceptance.
- **Reuse read (M106).** After `build_plan` + selection, before
  `run_schema_mutants`/`run_fallback_mutants`: partition the plan into
  *reusable* (store hit per §3) and *to-execute*. Reused mutants get their
  stored verdict injected into the ledger with a `reused: true` marker; only
  `to-execute` mutants reach the sandbox. `--incremental` gates this entire read
  path — absent, the partition is skipped and behaviour is v1.28 byte-identical.
- **`stable_id` is the join key** and is already cross-run stable for unchanged
  source positions (`Mut.StableId.compute`: file + byte offsets + mutator + kind;
  the byte offsets shift only when the file's earlier bytes change — which the
  function-level `source_digest` independently catches).

---

## Acceptance (this milestone)

- [x] Design doc committed; reuse table concrete per status (§3).
- [x] Digest granularity decided with rationale + empirical proof (§1).
- [x] Store format + location decided, isolated from the user source tree (§2).
- [x] `selected_tests_digest` + `config_digest` derivation decided (§4, §5).
- [x] Invalidation + GC bounded (§6).
- [x] No production code beyond the throwaway proof
      (`bench/spike/m104_history_proof.exs`, ALL PROOFS PASS).
- [ ] `bin/verify` green (run before commit).

## Out of scope (M105+)

- Implementation of `Mut.History.Store` / `Mut.History.Digest` (M105).
- `Mut.History.Reuse` + `--incremental` + `--since` (M106).
- Matrix correctness validation + benchmarks (M107).
- Making `--incremental` the default (a future, post-CI-validation decision).
