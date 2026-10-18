# Changelog

Mutalisk follows [Semantic Versioning](https://semver.org/). Before 1.0, the
public CLI, configuration, reports, and runtime helpers may change between minor
releases.

## 0.1.0

Initial release: mutation testing for Elixir 1.19 and newer.

- `MIX_ENV=test mix mut` plans mutations and runs selected tests in isolated
  subprocesses, using schema instrumentation or fallback recompilation.
- 13 default mutators and 17 additional opt-in or explicit-only mutators.
  See [the mutator catalogue](docs/MUTATORS.md).
- Coverage-based selection with conservative static fallbacks, transitive module
  references, and support for custom source roots and umbrella layouts.
- Fallback compilation preserves project configuration, compiler options, and
  each umbrella application's compilation context.
- Terminal and Stryker-compatible JSON reports by default; optional HTML and
  GitHub Actions reporters. JSON reports identify killing test files.
- Configuration through `.mutalisk.exs`, application config, and CLI flags;
  source exclusions and `@mutalisk_ignore` for generated or intentionally
  untested modules.
- Configurable per-test and whole-suite timeouts. Derived suite budgets use the
  baseline duration, with a cap and a per-test timeout floor.
- Sandbox resets restore sources and `priv/` files, directories, and symlinks;
  optional content hashing detects same-size fixture rewrites.
- Opt-in incremental history reuses verdicts only when project, mutant, and test
  digests match. Fingerprints include custom source roots and transitive path
  dependencies. Malformed or old history starts cold.
- Public `Mutalisk` helpers to inspect, set, and clear the VM-global active mutant.
- Apache License 2.0; no production dependencies.
