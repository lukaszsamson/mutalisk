# M55 follow-up — remaining OSS targets + VariableToLiteral (M56)

**Date:** 2026-05-24
**Scope:** the 6 deferred M55 targets (credo, req, timex, makeup, oban, ecto),
run with the v1.17 new opt-in surfaces **plus** the new `VariableToLiteral`
(M56), to (a) extend the M55 matrix and (b) collect VariableToLiteral's
keep/cut signal.

Config: `--enable pattern_literal,variable --mutators
variable_replace,variable_to_literal,atom_literal,integer_literal,string_literal,boolean_literal,nil_literal`
(large targets capped via `--max-mutants`). Pinned to the `../elixir_oss`
corpus SHAs.

## Results

| target | ran? | total | variable invalid | pattern-lit | var_to_literal | notes |
|---|---|---:|---:|---:|---:|---|
| makeup | ✅ | 503 | 2 (0.44%) | clean | 0/8 | weak test suite (36.7% overall kill — low everywhere) |
| ecto | ✅ (cap 1500) | 1500 | 11 (0.76%) | clean | 5/8 | macro-heavy; 188 codegen "errors" (detections) |
| credo | ⚠ partial | 7671 | **FALSE-high** | — | — | **engine false-invalid bug (below)**; too large for full run |
| timex | ❌ blocked | — | — | — | — | baseline: 5 Elixir-1.19/tzdata failures across 3 files |
| req | ❌ blocked | — | — | — | — | native dep `:ezstd` (zstd) fails to compile in this env |
| oban | ❌ blocked | — | — | — | — | needs Postgres + MySQL + SQLite repos + migrations; MySQL absent |

Combined with the M55 subset (decimal, jason, gettext, plug), **6 targets ran
to a usable result**. The blocked three are environment issues (toolchain
drift, native build, multi-DB infra), not mutalisk defects.

## Finding: fallback-recompile FALSE-INVALID on credo (engine bug)

credo reported a very high VariableReplace "invalid" rate (hundreds of invalids
across many files). **This is a mis-classification, confirmed:** a sampled
invalid mutant —
`lib/credo/check/warning/operation_with_constant_result.ex:55`, "replace
variable ctx with constant_result" — **compiles cleanly** both via full `mix
compile` (warning only: "variable ctx is unused") and via single-file
`Kernel.ParallelCompiler.compile_to_path/2` (mut's actual recompile path,
`lib/mut/recompile.ex`). So the mutant is valid, yet the fallback engine marked
it `:invalid`.

- **It is credo-specific.** ecto (also large, macro-heavy) had a clean 0.76%
  variable invalid rate. So this is not a generic large-codebase problem.
- **It is NOT a v1.17 mutator-correctness issue.** The mutators emit valid
  mutants; the fallback recompile/sandbox mis-reports them.
- **Hypotheses (unconfirmed)** for the engine follow-up: credo registers checks
  at compile time (`use Credo.Check`), so a single-file recompile in the
  sandbox may leave compile-time dependents stale, or parallel fallback workers
  contend on the shared sandbox build dir, or slow compiles interact with the
  timeout path (credo also showed many timeouts). Root-causing the fallback
  sandbox recompile is a separate engine task.

**Action:** filed as a known engine issue; does not change the v1.17 mutator
decisions. Recommend a follow-up to root-cause `Mut.Recompile`/sandbox behavior
on credo-shaped projects.

## VariableToLiteral (M56) keep/cut signal

- **Invalid: 0 everywhere** it ran (literals are valid wherever a value goes).
- **Low volume** — the deliberately narrow operator-only hint surface
  (`+ - * /`, `<>`, `++`/`--`) yields few candidates (8 on makeup, 8 in ecto's
  capped run).
- **Mixed kill**: ecto 5/8, makeup 0/8 (makeup's suite is weak, so 0/8 is
  "untested" not "equivalent").
- Equivalent-rate signal remains **thin** (too few mutants for a confident
  read). **Decision: keep_opt_in** (unchanged); revisit graduation only with a
  larger, clean-suite sample and a broader hint surface.

## Net v1.17 verdict (unchanged)

pattern-position literals and both variable mutators stay **opt-in**. Invalid
rates are within bar on every cleanly-runnable target. The one surprise was an
**engine** false-invalid on credo, surfaced (as intended) by broad validation —
tracked separately from the mutator work.
