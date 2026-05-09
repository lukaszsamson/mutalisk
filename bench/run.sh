#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="plug_crypto"
SELECTION="static"
CONCURRENCY="1"
WORKER_TYPE="mix"
ENABLE_BODY_LITERAL="0"

usage() {
  printf 'usage: bench/run.sh [--target decimal|plug_crypto|nimble_options|gettext|ecto|mox|jason|plug] [--selection static|coverage|coverage_with_static_fallback] [--concurrency N] [--worker-type mix|persistent] [--enable-body-literal]\n' >&2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --target)
      [ "$#" -ge 2 ] || { usage; exit 64; }
      TARGET="$2"
      shift 2
      ;;
    --selection)
      [ "$#" -ge 2 ] || { usage; exit 64; }
      SELECTION="$2"
      shift 2
      ;;
    --concurrency)
      [ "$#" -ge 2 ] || { usage; exit 64; }
      CONCURRENCY="$2"
      shift 2
      ;;
    --worker-type)
      [ "$#" -ge 2 ] || { usage; exit 64; }
      WORKER_TYPE="$2"
      shift 2
      ;;
    --enable-body-literal)
      ENABLE_BODY_LITERAL="1"
      shift 1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 64
      ;;
  esac
done

case "$TARGET" in
  decimal)
    REPO="https://github.com/lukaszsamson/decimal.git"
    REF="mutalisk-bench"
    SHA="78ff041047799f8bea75a47097430881cc9ba628"
    ;;
  plug_crypto)
    REPO="https://github.com/elixir-plug/plug_crypto.git"
    REF="v2.1.1"
    SHA="70af9d89e6bcb6fa7c47d42ef608e5c76a50d7ff"
    ;;
  # M25 v1.10 validation targets. SHAs pinned to latest stable tags
  # (queried 2026-05-09). BENCH_SHA / BENCH_REF env vars override for
  # one-off runs against newer upstream state, but the default is the
  # frozen v1.10 matrix anchor — do not bump without re-running the
  # M25 byte-identity gates.
  nimble_options)
    REPO="https://github.com/dashbitco/nimble_options.git"
    REF="${BENCH_REF:-v1.1.1}"
    SHA="${BENCH_SHA:-cc80e7e6fdb9bbbe6a4614b2e2e81ca4012fc264}"
    ;;
  gettext)
    REPO="https://github.com/elixir-gettext/gettext.git"
    REF="${BENCH_REF:-v1.0.2}"
    SHA="${BENCH_SHA:-e3180f138bda49c7607b709ec74133c47c24c81d}"
    ;;
  ecto)
    REPO="https://github.com/elixir-ecto/ecto.git"
    REF="${BENCH_REF:-v3.13.6}"
    SHA="${BENCH_SHA:-285329f63d34b610d754fd16d07f6c95ae52bfc7}"
    ;;
  mox)
    REPO="https://github.com/dashbitco/mox.git"
    REF="${BENCH_REF:-v1.2.0}"
    SHA="${BENCH_SHA:-5dd54291520f64e73186606befcaf5729307b237}"
    ;;
  jason)
    REPO="https://github.com/michalmuskala/jason.git"
    REF="${BENCH_REF:-v1.4.5}"
    SHA="${BENCH_SHA:-4ede42858eb19f80ec9e863aab52df466eab8608}"
    ;;
  plug)
    REPO="https://github.com/elixir-plug/plug.git"
    REF="${BENCH_REF:-v1.19.1}"
    SHA="${BENCH_SHA:-8723880aa55ec9aae26ec33bc2c107903ec16840}"
    ;;
  *)
    printf 'unsupported target: %s\n' "$TARGET" >&2
    usage
    exit 64
    ;;
esac

if [ -z "$SHA" ]; then
  printf 'BENCH_SHA must be set (export BENCH_SHA=<commit-sha>) for target %s\n' "$TARGET" >&2
  printf 'M24: pin a commit before benchmarking; do not run against moving HEAD.\n' >&2
  exit 64
fi

WORK_DIR="$ROOT/tmp/bench/$TARGET"
RESULTS_DIR="$ROOT/bench/results"
if [ "$CONCURRENCY" = "1" ]; then
  RESULT_PREFIX="$TARGET.$SELECTION"
else
  RESULT_PREFIX="$TARGET.$SELECTION.c$CONCURRENCY"
fi

if [ "$WORKER_TYPE" != "mix" ]; then
  RESULT_PREFIX="$RESULT_PREFIX.$WORKER_TYPE"
fi
if [ "$ENABLE_BODY_LITERAL" = "1" ]; then
  RESULT_PREFIX="$RESULT_PREFIX.body_literal"
  ENABLE_FLAGS=(--enable dispatch,guard,module_attribute,body_literal)
else
  ENABLE_FLAGS=()
fi
REPORT_PATH="$RESULTS_DIR/$RESULT_PREFIX.stryker.json"
TERMINAL_PATH="$RESULTS_DIR/$RESULT_PREFIX.terminal.txt"
REL_REPORT_PATH="bench/results/$RESULT_PREFIX.stryker.json"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

mkdir -p "$ROOT/tmp/bench" "$RESULTS_DIR"
rm -f "$REPORT_PATH" "$TERMINAL_PATH"

if [ -d "$WORK_DIR/.git" ]; then
  git -C "$WORK_DIR" fetch --tags --force origin
else
  rm -rf "$WORK_DIR"
  git clone "$REPO" "$WORK_DIR"
fi

git -C "$WORK_DIR" checkout --force "$SHA"

MIX_FILE="$WORK_DIR/mix.exs"
perl -0pi -e 's/(defp deps(?:\(\))? do\s*\[)/$1\n      {:mutalisk, path: System.fetch_env!("MUTALISK_PATH"), only: [:test], runtime: true},/s' "$MIX_FILE"

mkdir -p "$WORK_DIR/bench/results"

(
  cd "$WORK_DIR"
  printf 'target=%s repo=%s ref=%s sha=%s selection=%s concurrency=%s\n' "$TARGET" "$REPO" "$REF" "$SHA" "$SELECTION" "$CONCURRENCY"
  printf 'mutalisk_path=%s\n' "$ROOT"
  printf 'deps.get starting\n'
  MUTALISK_PATH="$ROOT" MIX_ENV=test MIX_BUILD_PATH="_build/bench_cli" MIX_DEPS_PATH="_build/bench_deps" mix deps.get
  printf 'mix mut starting\n'
  START_MS="$(date +%s)000"
  MUTALISK_PATH="$ROOT" MIX_ENV=test MIX_BUILD_PATH="_build/bench_cli" MIX_DEPS_PATH="_build/bench_deps" mix mut --fail-at 0 --selection "$SELECTION" --concurrency "$CONCURRENCY" --worker-type "$WORKER_TYPE" "${ENABLE_FLAGS[@]}" --output-path "$REL_REPORT_PATH"
  END_MS="$(date +%s)000"
  printf 'bench.wall_ms=%s\n' "$((END_MS - START_MS))"
) > "$TERMINAL_PATH" 2>&1

cp "$WORK_DIR/$REL_REPORT_PATH" "$REPORT_PATH"

ROOT="$ROOT" REPORT_PATH="$REPORT_PATH" TARGET="$TARGET" SELECTION="$SELECTION" elixir --eval '
Mix.install([{:jason, "~> 1.4"}])
report = System.fetch_env!("REPORT_PATH") |> File.read!() |> Jason.decode!()
engine = report["mutalisk"]["engine"]
mutants = report["files"] |> Map.values() |> Enum.flat_map(& &1["mutants"])

counts =
  Enum.reduce(mutants, %{}, fn mutant, acc ->
    bucket = Map.fetch!(engine, mutant["id"])
    status = mutant["status"]
    acc
    |> Map.update({bucket, :total}, 1, &(&1 + 1))
    |> Map.update({bucket, status}, 1, &(&1 + 1))
    |> Map.update({"combined", :total}, 1, &(&1 + 1))
    |> Map.update({"combined", status}, 1, &(&1 + 1))
  end)

score = fn bucket ->
  killed = Map.get(counts, {bucket, "Killed"}, 0)
  survived = Map.get(counts, {bucket, "Survived"}, 0)
  if killed + survived == 0, do: 100.0, else: Float.round(killed / (killed + survived) * 100, 1)
end

line =
    "bench target=#{System.fetch_env!("TARGET")} selection=#{System.fetch_env!("SELECTION")} " <>
    "schema=#{Map.get(counts, {"schema", :total}, 0)} score=#{score.("schema")}% " <>
    "fallback=#{Map.get(counts, {"fallback", :total}, 0)} score=#{score.("fallback")}% " <>
    "combined=#{Map.get(counts, {"combined", :total}, 0)} score=#{score.("combined")}% " <>
    "errors=#{Map.get(counts, {"combined", "RuntimeError"}, 0)} invalid=#{Map.get(counts, {"combined", "CompileError"}, 0)}"

IO.puts(line)
'
