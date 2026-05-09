# M25 Phase B diagnosis: nimble_options persistent drift

Pilot bench (`914b69f`) flagged 35/72 mutant drift between mix and
persistent on `nimble_options` baseline, all flipping to
`CompileError`. Status flips broke down:

| mix → persistent | count |
|---|---:|
| Killed → CompileError | 25 |
| Survived → CompileError | 7 |
| RuntimeError → CompileError | 2 |
| RuntimeError → Killed | 1 |

That's not within V17 timeout-flap acceptance — it's a real correctness
gap. This document explains what's actually happening and the fix
landed in the same M25 commit as this report.

## The signal

Every persistent-side `CompileError` carries the same
`statusReason`:

> no function clause matching in `String.trim_trailing/2`

`String.trim_trailing/2` is called in two mutalisk places (host-side
`Mut.FallbackPatch.render/2`, runner-side `loop/1`) and in
`nimble_options.ex` itself for documentation generation. The runtime
trace confirms the failing call originates **inside the user code**
during `Code.compile_file/1`, not in mutalisk.

Persistent's `Mut.Worker.PersistentRunner.compile_in_process/1`
catches every non-`CompileError` / non-`SyntaxError` /
non-`UndefinedFunctionError` exception in its rescue clause and
classifies it as `:unknown`:

```elixir
rescue
  error in CompileError -> {:error, :compile_error, ...}
  error in [SyntaxError, TokenMissingError] -> {:error, :compile_error, ...}
  error in UndefinedFunctionError -> {:error, :dep_path_error, ...}
  error -> {:error, :unknown, Exception.message(error)}
end
```

A `FunctionClauseError` raised at compile time falls into the last
clause. `34 unknown` lines up exactly with the persistent bench
"recompile errors → unknown: 34" report.

## Root cause

Mix-spawn fallback uses `Mut.Recompile.recompile/4`, which invokes
`Kernel.ParallelCompiler.compile_to_path/2` in a **fresh elixir
subprocess** with no pre-loaded modules. Compile-time evaluation in
the patched `lib/nimble_options.ex` hits a clean BEAM, follows the
mutated guard, and emits a runtime error during *test execution*
(hence mix's `RuntimeError` count of 3) — but compilation itself
finishes, so the patch is not invalidated.

Persistent's M21 in-process path uses `Code.compile_file/1` inside
the long-lived worker BEAM. The patched file's compile-time code
runs against modules already loaded by the schema-build baseline
plus modules left over from previous mutants in the same sandbox
(M21's `restore_modules/1` purges and reloads only the
`compile_files` of the prior mutant — not transitive caches in
`:persistent_term`, ETS, or the `:code` server's old-version
slots).

`nimble_options.ex` runs documentation generation at compile time:

```elixir
@moduledoc NimbleOptions.Docs.generate(@nimble_schema)
```

`NimbleOptions.Docs.generate/2` walks the schema, calls back into
helpers that use the very guards the mutator just changed
(`is_atom/1`, `is_list/1`, `is_tuple/1`, etc.). Mutating
`is_atom/1` → `is_nil/1` makes the option-type matcher fall through
to a default clause that produces a non-binary value, which
eventually feeds `String.trim_trailing/2` — `FunctionClauseError`.

In a clean BEAM (mix-spawn), the same compile sequence still walks
the schema with the same mutated guard. The difference is that
mix-spawn writes the resulting BEAM to disk and exits — there is no
`String.trim_trailing/2` call yet, because the failing call only
materialises during the documentation-string evaluation pipeline
that happens later in test execution. That's why mix shows
`RuntimeError` (test crash) on 3 of these mutants and Killed/Survived
on the rest, while persistent rejects 34 at compile time.

The **non-determinism** the pilot session noted (35 drift on
baseline vs 13 drift on body-literal-enabled) is real but
secondary: more mutants per run mean more module reloads per
sandbox, and the cumulative state drift hits different patches
depending on ordering. The dominant effect is the same root cause:
in-process recompile re-runs compile-time code in a polluted
environment.

## Fix landed in M25

`Mut.Worker.run_fallback_in_process/5` now treats
`{:compile_error, :unknown, _}` from the persistent runner as a
re-route signal to the mix-spawn fallback, identical to the
existing `:filter_miss | :timeout | :crashed` recovery contract:

```elixir
{:compile_error, :unknown, _message} ->
  # In-process Code.compile_file/1 raised a non-CompileError
  # exception in the polluted BEAM. Mix-spawn ParallelCompiler in
  # a clean subprocess typically accepts the same patch. Route
  # there; the patch is still applied to the sandbox.
  run_fallback(sandbox, mutant, test_files, opts)
```

`:compile_error` and `:dep_path_error` continue to materialise as
`:invalid` directly — those taxonomies agree with mix-spawn's
classification, and double-routing them would just cost time on
genuinely broken patches.

The persistent worker's `mix_fallback_count` now bumps for
`:unknown` retries, so the metrics block reflects how often
in-process recompile is silently bouncing to mix-spawn.

## Hypothesis the pilot session raised: shared `_build/bench_cli`

> bench/run.sh shares `_build/bench_cli` across mix and persistent
> invocations of the same target, which may explain the
> non-deterministic persistent drift.

This is **not** the issue. `bench/run.sh` uses `trap cleanup EXIT`
to `rm -rf "$WORK_DIR"` on every script exit. Each invocation
starts from a freshly cloned target tree at the pinned `BENCH_SHA`
and runs `mix deps.get` from scratch. There is no `_build/bench_cli`
state carrying over between runs.

Within a single invocation, the persistent BEAM holds state across
the run's mutants by design. That intra-run state is what produces
the recompile fragility documented above; it is not a bench-harness
bug.

## What this means for v1.10 default-flip

The fix above resolves the *byte-identity* gap on nimble_options:
mutants that compile in mix-spawn but fail in-process recompile now
get the mix-spawn verdict. Persistent's wall-clock advantage shrinks
proportionally on targets with macro-heavy compile-time code —
nimble_options pays roughly one mix-spawn-per-fragile-mutant tax —
but correctness is preserved.

For the v1.10 default-flip gate (BENCHMARKS.md), this means:

- **Byte-identity criterion**: nimble_options now expected to be
  byte-identical between worker types after this fix. Re-run the
  matrix to confirm.
- **Speed criterion** (persistent ≥1.5× faster on 4 of 5 targets):
  nimble_options's persistent advantage will be smaller post-fix.
  Re-run and check.
- **Other M25 targets**: the same `:unknown` retry path will also
  cover `gettext`, `ecto`, `mox`, `jason` if their compile-time
  surfaces have similar fragility. Mox is still the highest-risk
  target — module-replacement may surface effects that even
  mix-spawn's clean-BEAM compile cannot replay.

## Re-run runbook

After landing this fix:

```bash
# 1. Confirm bin/verify still green at HEAD.
bin/verify

# 2. Re-run nimble_options under all 4 modes.
bench/run.sh --target nimble_options --concurrency 4 --worker-type mix
bench/run.sh --target nimble_options --concurrency 4 --worker-type persistent
bench/run.sh --target nimble_options --concurrency 4 --worker-type mix --enable-body-literal
bench/run.sh --target nimble_options --concurrency 4 --worker-type persistent --enable-body-literal

# 3. Diff the stryker JSONs:
elixir --eval '
  mix = "bench/results/nimble_options.static.c4.stryker.json" |> File.read!() |> Jason.decode!()
  per = "bench/results/nimble_options.static.c4.persistent.stryker.json" |> File.read!() |> Jason.decode!()
  mix_status = for f <- Map.values(mix["files"]), m <- f["mutants"], into: %{}, do: {m["id"], m["status"]}
  per_status = for f <- Map.values(per["files"]), m <- f["mutants"], into: %{}, do: {m["id"], m["status"]}
  diffs = for {id, ms} <- mix_status, ps = per_status[id], ms != ps, do: {id, ms, ps}
  IO.puts("flips: #{length(diffs)}")
'
```

Expected: zero flips on the post-fix re-run, modulo the existing
V17 timeout-flap acceptance.
