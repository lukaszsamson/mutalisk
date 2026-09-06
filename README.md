# Mutalisk

Modern Elixir mutation testing. Mutalisk makes small changes ("mutants") to
your source — flip a `<` to `<=`, swap `Enum.filter` for `Enum.reject`, drop a
clause — then runs your test suite against each one. If a test fails, the
mutant is **killed** (your tests caught the bug). If every test still passes,
the mutant **survived** — a real gap in your suite's coverage that line
coverage can't see.

## Install

Add to your `mix.exs`:

    defp deps do
      [
        {:mutalisk, "~> 0.1", only: [:test], runtime: false}
      ]
    end

Run `mix deps.get`.

## Usage

    MIX_ENV=test mix mut

That builds the mutants, runs your tests against each, prints a summary, and
writes `stryker.report.json` (viewable in the
[Stryker mutation testing elements](https://stryker-mutator.io/) HTML viewer).

Because the dependency is `only: [:test]`, the task only exists under the test
environment — always run it with `MIX_ENV=test` (or add a `preferred_cli_env`
alias). `runtime: false` keeps Mutalisk out of your app's normal test start
graph; mutation workers enable the runtime dependency in their own overlay.
Plain `mix mut` in the default env fails with "task could not be found".

Useful flags (see `MIX_ENV=test mix help mut` or `mix mut --help` for the full
list):

    MIX_ENV=test mix mut --files "lib/my_app/core/**/*.ex"   # only mutate some files
    MIX_ENV=test mix mut --concurrency 8                      # parallel workers
    MIX_ENV=test mix mut --fail-at 70                         # exit non-zero below 70%
    MIX_ENV=test mix mut --reporters terminal,html           # pick reporters

Mutalisk runs your suite as-is (it does **not** pass `--warnings-as-errors`), so
compiler warnings in the target do not affect the mutation score. Keep your own
`mix compile --warnings-as-errors` gate in CI if you rely on it.

## Interpreting the score

The terminal summary reports a **mutation score** and a per-status breakdown:

- **Killed** — a test failed on the mutant. Good: your suite caught it.
- **Survived** — all selected tests passed on the mutant. A gap: no test
  distinguishes the mutated behaviour from the original.
- **Timeout** — the mutant made a test exceed its time budget (usually an
  infinite loop the mutation introduced). Counted as **detected** (like
  killed).
- **CompileError** / **RuntimeError** — the mutant didn't compile, or crashed
  the run for reasons unrelated to a test assertion. Excluded from the score.
- **NoCoverage** — no selected test executed for the mutant. Counted as
  undetected, like a survivor, because the report cannot prove a test guards it.
- **Ignored** — skipped (unsupported target, `@mutalisk_ignore`, or an
  `exclude` match). Excluded from the score.

The score is `detected / (detected + survived + no_coverage)` where
`detected = killed + timeout`. CompileError, RuntimeError, and Ignored mutants
are excluded from both — they don't measure test quality. This matches the
score the Stryker HTML viewer derives from the same report.

## Handling surviving mutants

Each surviving mutant is a specific, located suggestion. For each one, pick:

1. **Write or strengthen a test** (the usual answer). The survivor tells you
   exactly which behaviour is unguarded — e.g. "replace `<` with `<=` on
   `lib/foo.ex:12` survived" means no test pins the boundary.
2. **Decide it's equivalent** — the mutation produces behaviour that is
   genuinely indistinguishable (e.g. a defensive branch the spec doesn't
   constrain). Mutation testing can't decide equivalence for you; some
   survivors are expected.
3. **Exclude it from mutation** when the code is intentionally untested
   (generated/DSL modules, glue): add `@mutalisk_ignore true` to the module
   (see below), or an `exclude` path pattern in config.

Use `--reporters html` for a clickable report of every survivor with its
source line and mutation, or `--reporters github-actions` to get inline PR
annotations in CI.

## Source-level ignores

Add `@mutalisk_ignore true` anywhere in a module's body to exclude every
mutant in that module:

    defmodule MyApp.Generated do
      @mutalisk_ignore true
      # ... no mutants are produced here ...
    end

## Configuration

Settings layer, lowest to highest precedence:

    .mutalisk.exs project file  <  legacy config :mut  <  config :mutalisk  <  CLI flags

(`config :mut` is a deprecated namespace kept for compatibility; prefer
`config :mutalisk`.)

`.mutalisk.exs` (project root, optional) is a plain keyword list:

    # .mutalisk.exs
    [
      selection: :coverage_with_static_fallback,
      fail_at: 75.0,
      concurrency: 8,
      exclude: [~r"lib/my_app_web/router.ex"]
    ]

Or `config :mutalisk, ...` in `config/test.exs`. CLI flags override both. Run
`MIX_ENV=test mix help mut` or `mix mut --help` for every key and flag.

## Mutators

13 low-noise mutators run by default; 17 more are opt-in or explicit-only. See
[docs/MUTATORS.md](docs/MUTATORS.md) for the full catalogue and enablement
rules.

## Reporters

- `terminal` (default) — the summary printed to stdout.
- `stryker-json` (default) — `stryker.report.json` for the Stryker HTML viewer.
- `html` (opt-in) — a self-contained `stryker.report.html` listing survivors.
- `github-actions` (opt-in) — `::warning` annotations for inline PR comments.

Select with `--reporters a,b` or `config :mutalisk, reporters: [...]`. Config may
use atoms such as `:stryker_json`; CLI examples use the hyphenated names.

## Per-test timeout policy

Mutalisk runs ExUnit with a **10 000 ms per-test timeout** (not ExUnit's
60 000 ms default), passed as `mix test --timeout 10000`. Override with
`--test-timeout-ms` or `config :mutalisk, test_timeout_ms: N`.

Mutation-introduced bugs are usually infinite loops or unbounded recursion —
1–10 s is plenty of evidence to classify them, and a 60 s timeout per such
mutant dominates wall-clock. If a test legitimately needs longer under no
mutation, tag it (`@tag timeout: 60_000`); ExUnit per-test tags override the
global default.

### Whole-suite (host) deadline

The per-test timeout bounds one test; the host also bounds the **whole selected
suite** for a mutant and kills the test port when that budget elapses. Because
several individually valid slow tests can exceed a budget sized for one test —
and the resulting host timeout would be scored as a detection, inflating the
score — the host deadline is derived from the measured baseline run:

    max(test_timeout_ms, baseline_wall_ms * 2) + 10 000 ms

Set `--suite-timeout-ms N` (or `config :mutalisk, suite_timeout_ms: N`, range
1 000..3 600 000) to pin it explicitly; the same 10 000 ms drain buffer is added
so ExUnit can report its own timeout first. Each run prints the deadline it
derived and why.

### Sandbox `priv/` reset

Every mutant runs in a sandbox whose `priv/` tree is restored between mutants,
so a database, generated asset, directory or symlink a test writes there never
leaks into the next mutant. Baseline `priv/` files are compared by size + mtime
(`priv_fingerprint: :stat`, the default) — cheap, but blind to a rewrite that
keeps the byte size **and** lands in the same mtime second. Set
`--priv-fingerprint hash` (or `config :mutalisk, priv_fingerprint: :hash`) for a
content-exact comparison; it costs one content read per `priv/` file per reset,
per worker.

## Test selection

Test selection decides which test files run for each mutant. It defaults to
`coverage_with_static_fallback`; `--selection static` is the fully-portable
escape hatch and `--selection coverage` is the strict (no-fallback) coverage
mode. Selection only ever affects *which* tests run — it never enters a mutant's
stable id — and every rule below errs towards running more tests, because
under-selecting a killing test would report a false survivor.

In the coverage modes each mutant takes the first non-empty scope from:

1. **exact line** — tests whose coverage includes the mutated line.
2. **enclosing function** — tests covering any line of the mutated function.
3. **enclosing file** — tests covering any line of the mutated file.
4. **static fallback** — tests statically referencing the mutant's module.
5. **all tests**.

Two rules deliberately widen that ladder:

- **Clause-head mutations skip exact-line coverage.** A mutation in a pattern
  or a guard can make its clause accept inputs that originally routed to a
  *different* clause, so the killing test need never have executed the mutated
  line. Those mutants start at enclosing-function scope (every clause of the
  function) and fall back to whole-file scope when function metadata is
  unavailable.
- **Degraded coverage is unknown coverage.** Any test file whose coverage
  collection timed out or failed is added to *every* mutant's selection. An
  absent measurement is not evidence that the test is irrelevant.

Static selection is **conservative and may select more tests than strictly
necessary**. It indexes the modules each test file names, and then follows a
module reference graph built over `lib/` and `test/support/` (plus `apps/*` for
umbrellas): a test is selected for a target module when it references that
module *or any module that transitively references it*. This is what makes a
test that reaches the target only through a facade module still run. When the
closure spans the whole project, selecting every test is the correct answer.
The graph is built from statically visible aliases, so runtime-computed module
names are still handled by the separate dynamic-dispatch escape hatch (a test
file using `apply/3` on a variable module, or `Module.concat/1`, is selected for
every mutant).

## Limitations

- Mutalisk does not mutate DSL-emitted code, macro bodies, or generated code.
- Static test selection over-approximates; see [Test selection](#test-selection).
- Mutants run via a fresh `mix test` worker each (one mutant per VM), in an
  isolated sandbox subprocess.

## Project documents

- [docs/MUTATORS.md](docs/MUTATORS.md) — the mutator catalogue
- [HLD](https://github.com/lukaszsamson/mutalisk/blob/main/ELIXIR_MUTATION_TESTING_HLD_V1_5_V2.md) — latest design / spec on `main`
- [PLAN.md](https://github.com/lukaszsamson/mutalisk/blob/main/PLAN.md) — latest milestone history on `main`
- [BENCHMARKS.md](https://github.com/lukaszsamson/mutalisk/blob/main/BENCHMARKS.md) — latest OSS validation runs on `main`
- [docs/BOOTSTRAP.md](https://github.com/lukaszsamson/mutalisk/blob/main/docs/BOOTSTRAP.md) — latest child-process bootstrap design on `main`
