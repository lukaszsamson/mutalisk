#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="plug_crypto"

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

case "$TARGET" in
  plug_crypto)
    EXPECTED_SCHEMA=43
    EXPECTED_FALLBACK=21
    EXPECTED_COMBINED=64
    ;;
  decimal)
    EXPECTED_SCHEMA=""
    EXPECTED_FALLBACK=""
    EXPECTED_COMBINED=""
    ;;
  *)
    printf 'unsupported target: %s\n' "$TARGET" >&2
    exit 64
    ;;
esac

REPORT_PATH="$ROOT/bench/results/$TARGET.stryker.json"

if [ ! -f "$REPORT_PATH" ]; then
  printf 'missing benchmark report: %s\n' "$REPORT_PATH" >&2
  exit 1
fi

REPORT_PATH="$REPORT_PATH" EXPECTED_SCHEMA="$EXPECTED_SCHEMA" EXPECTED_FALLBACK="$EXPECTED_FALLBACK" EXPECTED_COMBINED="$EXPECTED_COMBINED" mix run --no-start -e '
report = System.fetch_env!("REPORT_PATH") |> File.read!() |> Jason.decode!()

case Mut.Reporter.StrykerJson.validate(report) do
  :ok -> :ok
  {:error, violations} -> Mix.raise("invalid Stryker JSON: #{inspect(violations)}")
end

mutants =
  report["files"]
  |> Map.values()
  |> Enum.flat_map(& &1["mutants"])

errors = Enum.count(mutants, &(&1["status"] == "RuntimeError"))
invalid = Enum.count(mutants, &(&1["status"] == "CompileError"))

if errors > 0 do
  Mix.raise("benchmark report contains #{errors} error-status mutants")
end

if invalid > 0 do
  Mix.raise("benchmark report contains #{invalid} invalid mutants")
end

engine = report["mutalisk"]["engine"]

actual_counts = %{
  "schema" => Enum.count(mutants, &(engine[&1["id"]] == "schema")),
  "fallback" => Enum.count(mutants, &(engine[&1["id"]] == "fallback")),
  "combined" => length(mutants)
}

expected_counts = %{
  "schema" => System.fetch_env!("EXPECTED_SCHEMA"),
  "fallback" => System.fetch_env!("EXPECTED_FALLBACK"),
  "combined" => System.fetch_env!("EXPECTED_COMBINED")
}

expected_counts
|> Enum.reject(fn {_bucket, expected} -> expected == "" end)
|> Enum.each(fn {bucket, expected} ->
  expected = String.to_integer(expected)
  actual = Map.fetch!(actual_counts, bucket)

  if actual != expected do
    Mix.raise("expected #{expected} #{bucket} mutants, got #{actual}")
  end
end)

IO.puts("bench.verify target=#{Path.basename(System.fetch_env!("REPORT_PATH"), ".stryker.json")} stryker_json=:ok errors=0 invalid=0 counts=#{inspect(actual_counts)}")
'
