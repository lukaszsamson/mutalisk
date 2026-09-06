# Changelog

All notable changes to Mutalisk are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and Mutalisk aims to adhere to [Semantic Versioning](https://semver.org/).

> Mutalisk is pre-1.0 (`0.x`): the public surface (CLI flags, config keys,
> report shape) is stable in practice but may still change before `1.0.0`.

## Unreleased

### Changed
- Incremental history format version 2: records now carry `suite_timeout_ms`
  and the killing test file; version-1 stores are rebuilt cold.
- Mutant test runs are reaped by process group as well as by descendant walk,
  so a wrapper `mix`/`elixir` that exits early no longer leaks the mutant BEAM.
- Sandbox resets restore directories and symlinks under `priv/` and `lib/`,
  not only regular files.

### Changed (second audit round)
- Fallback recompiles load the project and its config (`Application.compile_env`,
  `Mix.Project.config`, `elixirc_options` incl. `warnings_as_errors`) like `mix compile`.
- Test selection: clause-head (pattern/guard) mutants select at function or file
  scope; tests with unknown (degraded) coverage always run; static selection
  follows module references transitively.
- Sandbox resets never traverse a symlinked root and restore fallback-patched
  sources outside `lib/`.
- Incremental history fingerprints path dependencies and extra `elixirc_paths`
  roots, disables reuse when they cannot be resolved, and cold-starts on a
  malformed store instead of crashing.

### Added
- `--suite-timeout-ms` / `suite_timeout_ms`: explicit whole-suite host budget;
  otherwise derived from the baseline wall time (capped) and the per-test timeout.
- `--priv-fingerprint stat|hash` / `priv_fingerprint`: how `priv/` files are
  compared on reset.
- `--test-paths` CLI switch.
- Stryker report `testFiles` table; `killedBy` references the killing test file.

### Fixed
- Dozens of correctness fixes from the September 2026 audit (BUGS_TRIAGED.txt):
  identity/invalid mutants, EnvWalker recall, umbrella app-name mapping and
  rollback paths, incremental digests, UTF-8 in reports, setup error handling,
  sandbox and work-copy leaks.

## 0.1.0 — first release

The initial public release. Mutalisk is a mutation-testing engine for Elixir:
it systematically introduces small faults ("mutants") into your code, runs your
tests against each, and reports which mutants survived — the gaps where your
tests don't actually pin down behavior.

### Highlights

- **`mix mut`** — run mutation testing against the current project (under
  `MIX_ENV=test`). See `mix help mut` for the full flag reference.
- **Two execution engines.** Dispatch and scalar-literal mutants run through a
  single schema-instrumented build (fast); structural, pattern, guard, and
  collection mutants run through per-mutant fallback recompilation. Both
  execute in **sandboxed subprocesses** — the trust anchor that keeps a mutant
  from corrupting the runner.
- **Mutator catalogue** — 13 default-on mutators (arithmetic, comparison,
  boolean, dispatch swaps, atom/integer literals, pins, and more) plus 16 opt-in
  ones. Full catalogue and enable/disable guidance in
  [the mutator reference](docs/MUTATORS.md).
- **Coverage-based test selection** (`--selection`, default
  `coverage_with_static_fallback`) — only run the tests that actually cover
  each mutant, with a per-file static fallback when coverage is unavailable.
- **Umbrella support** — mutates and tests across apps in an umbrella project,
  including cross-app dependents.
- **Reports** — Stryker-compatible JSON (`stryker.report.json`) and a terminal
  summary by default; opt-in HTML and GitHub Actions (PR annotation) reporters.
- **Configuration** — layered `.mutalisk.exs` file < `config :mutalisk` < CLI
  flags; exclude files by pattern; `@mutalisk_ignore true` to skip a module.
- **Incremental cross-run history** (`--incremental`, opt-in) — reuse a prior
  run's verdicts when the project is unchanged. Reuse is gated on a coarse
  project fingerprint (all `lib`/test-support/config sources plus `mix.lock`)
  **and** the per-mutant function source and selected tests; any project change
  invalidates the whole store and re-runs every mutant. This makes it
  crash/interrupt recovery and an identical-tree fast path, **not** diff-scoped
  reuse. Conservative (exact digest match); never changes the answer.

### Requirements

- Elixir `>= 1.19.0` (uses the built-in `JSON` module; no JSON dependency).

### License

- Apache License 2.0.

---

Per-milestone development history (the internal v1.x milestone arc) lives in
the source repository, not in the packaged changelog.
