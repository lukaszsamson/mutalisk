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

## How It Works

See [SPEC](ELIXIR_MUTATION_TESTING_SPEC.md) and [PLAN](PLAN.md).

Authoritative project documents:

- [ELIXIR_MUTATION_TESTING_SPEC.md](ELIXIR_MUTATION_TESTING_SPEC.md)
- [PLAN.md](PLAN.md)
- [docs/BOOTSTRAP.md](docs/BOOTSTRAP.md)
