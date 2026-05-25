# M58 — fallback-recompile engine hardening

**Date:** 2026-05-25
**Goal:** explain/close the credo invalid residual and harden the fallback
recompile for projects with compile-time-process-dependent code.

## Root cause of the credo invalid rate (explained)

The credo invalids decomposed into three causes, all now addressed:

1. **Compile-time Mix access crash (the bulk — engine bug).** `use Credo.Check`
   reaches `Mix.ProjectStack` at COMPILE time. The fallback recompile runs
   `Kernel.ParallelCompiler` in a bare `elixir --eval` BEAM that does not start
   `:mix`, so compilation crashed (`(exit) GenServer.call(Mix.ProjectStack…) no
   process`) → valid mutants mis-classified `:invalid`. **Fixed in v1.17 by
   `Mix.start()` in the recompile eval (`9818aeb`)** — dropped credo invalid
   ~40% → 10.3%.
2. **for/unquote metaprogramming (the 10.3% residual).** A module-level
   `for {sigil_start, sigil_end} <- … do defp … unquote(sigil_end) … end`
   produced ~40 variable candidates for the for-generator/unquote-injected
   names; mutating them breaks the generated clauses. **Addressed by M57's
   codegen-function skip** — verified: `collect_variable_candidates/2` on
   `credo/lib/credo/code/charlists.ex` now emits **0** `sigil_end`/`sigil_start`
   candidates (was the false-invalid source).
3. **pipe-rhs / `&`-capture function names** (`x |> to_string`, `&f/n`). Fixed
   in v1.17 (`06a1280`).

So the credo invalid rate is fully explained: one genuine engine bug (Mix not
started — fixed) plus two mutator false-positive classes (now suppressed). It
was never a sandbox-staleness / parallel-contention / timeout issue — those
hypotheses from M55 are ruled out (the single-file `compile_to_path` reproduced
the crash deterministically, and `Mix.start()` alone fixes it).

## Hardening + regression coverage

- The `Mix.start()` recompile-eval bootstrap (`9818aeb`) is the hardening for
  `use`-macro-registration / compile-time-`Mix.Project` projects.
- **New regression fixture** (`recompile_test.exs`, `:integration`): a module
  with compile-time `Mix.Project.config()` recompiles cleanly via the eval's
  `Mix.start()` bootstrap, and fails without it (negative control) — locking in
  the fix end-to-end.
- `elixir_args/3` unit test asserts the eval contains `Mix.start()` before
  `compile_to_path`.

## Acceptance

- credo invalid rate explained (above): engine bug fixed + two false-positive
  classes suppressed; no sandbox/contention/timeout cause.
- Fixture recompiles correctly under the fallback engine (`:integration` test).
- No regression on the M55 clean targets (`bin/verify` green; decimal/jason/
  ecto unaffected — they have no compile-time-Mix code).

*Out of scope:* schema-routing more mutators to avoid recompile (not v1.18).
The full post-fix credo number is re-measured in the M59 matrix.
