# Mutalisk

Modern Elixir mutation testing.

## Install

Add to your `mix.exs`:

    defp deps do
      [
        {:mutalisk, "~> 0.1", only: [:test]}
      ]
    end

Run `mix deps.get`.

## Usage

Run mutation testing:

    MIX_ENV=test mix mut

Outputs `stryker.report.json` for the [Stryker mutation testing elements](https://stryker-mutator.io/) HTML viewer.

## Configuration

See `mix help mut` for full CLI flags. Common config:

    config :mut,
      files: ["lib"],
      test_paths: ["test"],
      enabled_targets: [:dispatch, :guard],
      fail_at: 80.0

## Per-test timeout policy (v1.8+)

Mutalisk runs ExUnit with a **10 000 ms per-test timeout**, not
the ExUnit default of 60 000 ms (passed as `mix test --timeout
10000`). Override with `--test-timeout-ms` or
`config :mut, test_timeout_ms: N`.

This is a deliberate mutation-testing policy, not an
implementation detail:

- Mutation-introduced bugs are CPU-bound infinite loops or
  unbounded recursion. We don't need 60 s of evidence to
  classify them — 1-10 s is plenty.
- A single ExUnit's-default-timeout mutant blocks one worker
  for a full minute. Across a Decimal-class target with
  ~20 timeout-class mutants, this dominated wall-clock
  (~5 minutes wasted at c=4 on the 60 s default).
- Application tests that exercise external systems and
  legitimately need more time can override per-test via the
  standard `@tag timeout: 60_000` (or any other ms value).
  ExUnit per-test tags override the global default.

If your suite has tests that legitimately exceed 10 s under no
mutation, tag them. Otherwise no change is needed.

## How It Works

See [SPEC](ELIXIR_MUTATION_TESTING_SPEC.md) and [PLAN](PLAN.md).

## Benchmarks

See [BENCHMARKS.md](BENCHMARKS.md) for the v1 real-project smoke run. The reference run validates Mutalisk against a pinned OSS library checkout and records score, mutant counts, skipped reasons, invalid/error counts, and wall-clock behavior outside the demo fixture.

## Limitations

Mutalisk does not mutate DSL-emitted code, user macro bodies, patterns, or generated code. Test selection is static by default with coverage-based selection available opt-in (`--selection coverage` / `coverage_with_static_fallback`). Mutants run in parallel (`--concurrency N`, default `min(schedulers_online, 4)`). Body-context literal mutators (integer, boolean, string, float, nil, allowlisted atoms, and list/2-tuple emptying) are available opt-in via `--enable`. Incremental history and wrapper-schemata are candidates for later versions.

Mutation runs use a single worker model (a fresh `mix test` per mutant). The opt-in persistent worker was removed in v1.15; `--worker-type mix` is accepted as a deprecated no-op and `--worker-type persistent` is rejected.

Authoritative project documents:

- [ELIXIR_MUTATION_TESTING_SPEC.md](ELIXIR_MUTATION_TESTING_SPEC.md)
- [PLAN.md](PLAN.md)
- [docs/BOOTSTRAP.md](docs/BOOTSTRAP.md)
