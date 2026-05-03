#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="decimal"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --target)
      [ "$#" -ge 2 ] || { printf 'missing --target value\n' >&2; exit 64; }
      TARGET="$2"
      shift 2
      ;;
    *)
      printf 'usage: bench/verify.sh [--target decimal|plug_crypto]\n' >&2
      exit 64
      ;;
  esac
done

REPORT_PATH="$ROOT/bench/results/$TARGET.stryker.json"

if [ ! -f "$REPORT_PATH" ]; then
  printf 'missing benchmark report: %s\n' "$REPORT_PATH" >&2
  exit 1
fi

REPORT_PATH="$REPORT_PATH" mix run --no-start -e '
report = System.fetch_env!("REPORT_PATH") |> File.read!() |> Jason.decode!()

case Mut.Reporter.StrykerJson.validate(report) do
  :ok -> :ok
  {:error, violations} -> Mix.raise("invalid Stryker JSON: #{inspect(violations)}")
end

errors =
  report["files"]
  |> Map.values()
  |> Enum.flat_map(& &1["mutants"])
  |> Enum.count(&(&1["status"] == "RuntimeError"))

if errors > 0 do
  Mix.raise("benchmark report contains #{errors} error-status mutants")
end

IO.puts("bench.verify target=#{Path.basename(System.fetch_env!("REPORT_PATH"), ".stryker.json")} stryker_json=:ok errors=0")
'
