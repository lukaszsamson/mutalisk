# Changelog

All notable changes to Mutalisk are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and Mutalisk aims to adhere to [Semantic Versioning](https://semver.org/).

> Mutalisk is pre-1.0 (`0.x`): the public surface (CLI flags, config keys,
> report shape) is stable in practice but may still change before `1.0.0`.

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
  boolean, dispatch swaps, conditionals, literals, and more) plus 16 opt-in
  ones. Full catalogue and enable/disable guidance in
  [the mutator reference](docs/MUTATORS.md).
- **Coverage-based test selection** (`--selection`, default
  `coverage_with_static_fallback`) — only run the tests that actually cover
  each mutant, with a per-file static fallback when coverage is unavailable.
- **Umbrella support** — mutates and tests across apps in an umbrella project,
  including cross-app dependents.
- **Reports** — Stryker-compatible JSON (`stryker.report.json`) and a terminal
  summary by default; opt-in HTML and GitHub Actions (PR annotation) reporters.
- **Configuration** — layered `.mutalisk.exs` file < `config :mut` < CLI flags;
  exclude files by pattern; `@mutalisk_ignore true` to skip a module.
- **Incremental cross-run history** (`--incremental`, opt-in) — reuse the
  verdicts of mutants whose enclosing function and selected tests are unchanged,
  re-executing only what changed. Built for fast CI re-runs; reuse is
  conservative (exact digest match) and never changes the answer.

### Requirements

- Elixir `>= 1.19.0` (uses the built-in `JSON` module; no JSON dependency).

### License

- Apache License 2.0.

---

Per-milestone development history (the internal v1.x milestone arc) lives in
`PLAN.md` and the `docs/decisions/` records, not here.
