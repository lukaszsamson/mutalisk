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
        {:mutalisk, "~> 0.1", only: [:test]}
      ]
    end

Run `mix deps.get`.

## Usage

    MIX_ENV=test mix mut

That builds the mutants, runs your tests against each, prints a summary, and
writes `stryker.report.json` (viewable in the
[Stryker mutation testing elements](https://stryker-mutator.io/) HTML viewer).

Useful flags (see `mix help mut` for the full list):

    mix mut --files "lib/my_app/core/**/*.ex"   # only mutate some files
    mix mut --concurrency 8                       # parallel workers
    mix mut --fail-at 70                          # exit non-zero below 70%
    mix mut --reporters terminal,html             # pick reporters

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
- **Ignored** — skipped (unsupported target, `@mutalisk_ignore`, or an
  `exclude` match). Excluded from the score.

The score is `detected / (detected + survived)` where `detected = killed +
timeout`. CompileError, RuntimeError, and Ignored mutants are excluded from
both — they don't measure test quality. This matches the score the Stryker
HTML viewer derives from the same report.

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
source line and mutation, or `--reporters github_actions` to get inline PR
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

    .mutalisk.exs project file  <  config :mut  <  CLI flags

`.mutalisk.exs` (project root, optional) is a plain keyword list:

    # .mutalisk.exs
    [
      selection: :coverage_with_static_fallback,
      fail_at: 75.0,
      concurrency: 8,
      enabled_targets: [:dispatch, :guard],
      exclude: [~r"lib/my_app_web/router.ex"]
    ]

Or `config :mut, ...` in `config/test.exs`. CLI flags override both. Run
`mix help mut` for every key and flag.

## Mutators

13 low-noise mutators run by default; 16 more are opt-in. See
[docs/MUTATORS.md](docs/MUTATORS.md) for the full catalogue and how to enable
the opt-in ones.

## Reporters

- `terminal` (default) — the summary printed to stdout.
- `stryker_json` (default) — `stryker.report.json` for the Stryker HTML viewer.
- `html` (opt-in) — a self-contained `stryker.report.html` listing survivors.
- `github_actions` (opt-in) — `::warning` annotations for inline PR comments.

Select with `--reporters a,b` or `config :mut, reporters: [...]`.

## Per-test timeout policy

Mutalisk runs ExUnit with a **10 000 ms per-test timeout** (not ExUnit's
60 000 ms default), passed as `mix test --timeout 10000`. Override with
`--test-timeout-ms` or `config :mut, test_timeout_ms: N`.

Mutation-introduced bugs are usually infinite loops or unbounded recursion —
1–10 s is plenty of evidence to classify them, and a 60 s timeout per such
mutant dominates wall-clock. If a test legitimately needs longer under no
mutation, tag it (`@tag timeout: 60_000`); ExUnit per-test tags override the
global default.

## Limitations

- Mutalisk does not mutate DSL-emitted code, macro bodies, or generated code.
- Test selection defaults to `coverage_with_static_fallback`; `--selection
  static` is the fully-portable escape hatch and `--selection coverage` is the
  strict (no-fallback) coverage mode.
- Mutants run via a fresh `mix test` worker each (one mutant per VM). The
  opt-in persistent worker was removed in v1.15; `--worker-type mix` is a
  deprecated no-op and `--worker-type persistent` is rejected.

## Project documents

- [docs/MUTATORS.md](docs/MUTATORS.md) — the mutator catalogue
- [ELIXIR_MUTATION_TESTING_SPEC.md](ELIXIR_MUTATION_TESTING_SPEC.md) — the spec
- [PLAN.md](PLAN.md) — milestone history
- [BENCHMARKS.md](BENCHMARKS.md) — OSS validation runs
- [docs/BOOTSTRAP.md](docs/BOOTSTRAP.md) — the child-process bootstrap design
