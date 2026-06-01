#!/usr/bin/env bash
# M97 sharding harness — the strategy that lets the matrix run actually
# complete (M93/M95 deferred it twice on session-envelope grounds).
#
# Insight: the expensive part is clone + deps.get + compile PER TARGET.
# A focused `mix mut --enable <flag> --mutators <name> --max-mutants N`
# against an already-compiled work_copy is cheap (only that surface's
# candidates are generated, run is bounded). So: shard = one target,
# clone/compile ONCE, loop all surfaces against the persistent work_copy.
#
# Usage:
#   bench/shard_matrix.sh --target decimal [--surfaces nc,sd,cd,...] \
#       [--max-mutants 40] [--selection coverage_with_static_fallback]
#
# Surface keys -> (enable target, mutator name):
#   nc  -> conditional        / negate_conditional
#   sd  -> statement_delete    / statement_delete
#   cd  -> clause_delete       / clause_delete       (incl. receive/try sections)
#   gb  -> guard_boolean       / guard_boolean
#   pd  -> pipeline_drop       / pipeline_drop_stage
#   mu  -> map_update_drop     / map_update_drop
#   rt  -> receive_timeout     / receive_timeout
#   fr  -> dispatch            / function_replace
#   pin -> pattern_shape       / pin
#
# Reports land in bench/results/matrix/<target>.<surface>.stryker.json and a
# one-line summary per (target, surface) is appended to
# bench/results/matrix/summary.txt.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET=""
SURFACES="nc,sd,cd,gb,pd,mu,rt,fr,pin"
MAX_MUTANTS="40"
SELECTION="coverage_with_static_fallback"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --target) TARGET="$2"; shift 2;;
    --surfaces) SURFACES="$2"; shift 2;;
    --max-mutants) MAX_MUTANTS="$2"; shift 2;;
    --selection) SELECTION="$2"; shift 2;;
    *) echo "unknown arg: $1" >&2; exit 64;;
  esac
done

[ -n "$TARGET" ] || { echo "missing --target" >&2; exit 64; }

case "$TARGET" in
  decimal)           REPO="https://github.com/lukaszsamson/decimal.git";              SHA="78ff041047799f8bea75a47097430881cc9ba628";;
  plug_crypto)       REPO="https://github.com/elixir-plug/plug_crypto.git";           SHA="70af9d89e6bcb6fa7c47d42ef608e5c76a50d7ff";;
  jason)             REPO="https://github.com/michalmuskala/jason.git";               SHA="4ede42858eb19f80ec9e863aab52df466eab8608";;
  bandit)            REPO="https://github.com/mtrudel/bandit.git";                    SHA="d15dd87082a0cc48530b5ad71f5e270fd94c69c9";;
  phoenix)           REPO="https://github.com/phoenixframework/phoenix.git";          SHA="c86dd55d242f2f9e49054d28af9745a58748c6b0";;
  phoenix_live_view) REPO="https://github.com/phoenixframework/phoenix_live_view.git"; SHA="f73eac3e388eda4677025f0cb374c7d804f53f74";;
  *) echo "unsupported target for shard harness: $TARGET" >&2; exit 64;;
esac

[ -n "$SHA" ] || { echo "set SHA for $TARGET (export BENCH_SHA=...)" >&2; exit 64; }

WORK_DIR="$ROOT/tmp/bench/shard/$TARGET"
RESULTS_DIR="$ROOT/bench/results/matrix"
mkdir -p "$RESULTS_DIR"

# Clone + prep ONCE (idempotent: skip if work_copy already compiled).
if [ ! -f "$WORK_DIR/.shard_ready" ]; then
  rm -rf "$WORK_DIR"
  git clone -q "$REPO" "$WORK_DIR"
  git -C "$WORK_DIR" -c advice.detachedHead=false checkout --force "$SHA"

  # Inject mutalisk dep (def or defp deps).
  perl -0pi -e 's/((?:def|defp) deps(?:\(\))? do\s*\[)/$1\n      {:mutalisk, path: System.fetch_env!("MUTALISK_PATH"), only: [:test], runtime: true},/s' "$WORK_DIR/mix.exs"

  # Per-target prep (mirrors bench/run.sh).
  case "$TARGET" in
    jason)
      perl -pi -e 's/ExUnit\.start\(\)/ExUnit.start(seed: 42)/' "$WORK_DIR/test/test_helper.exs"
      ;;
    bandit)
      rm -f "$WORK_DIR/.tool-versions"
      perl -i -pe 's/^(\s*)(test "reading ssl data")/$1\@tag :otp_ssl_cipher_drift\n$1$2/' "$WORK_DIR/test/bandit/http2/plug_test.exs"
      perl -pi -e 's/ExUnit\.start\(exclude: :slow\)/ExUnit.start(exclude: [:slow, :otp_ssl_cipher_drift], seed: 42)/' "$WORK_DIR/test/test_helper.exs"
      ;;
    phoenix)
      rm -f "$WORK_DIR/.tool-versions"
      perl -pi -e 's/ExUnit\.start\(([^)]*)\)/ExUnit.start($1, seed: 42)/' "$WORK_DIR/test/test_helper.exs"
      ;;
    phoenix_live_view)
      rm -f "$WORK_DIR/.tool-versions"
      perl -i -pe 's/^(\s*)(test "does not format when empty")/$1\@tag :env_drift\n$1$2/' "$WORK_DIR/test/phoenix_live_view/html_formatter_test.exs"
      perl -i -pe 's/^(\s*)(test "live render with socket.assigns")/$1\@tag :env_drift\n$1$2/' "$WORK_DIR/test/phoenix_live_view/integrations/live_view_test.exs"
      perl -i -pe 's/^(\s*)(test "fill in calendar types")/$1\@tag :env_drift\n$1$2/' "$WORK_DIR/test/phoenix_live_view/integrations/elements_test.exs"
      perl -pi -e 's/ExUnit\.start\(\)/ExUnit.start(exclude: [:env_drift], seed: 42)/' "$WORK_DIR/test/test_helper.exs"
      ;;
  esac

  ( cd "$WORK_DIR" && MUTALISK_PATH="$ROOT" MIX_ENV=test MIX_BUILD_PATH="_build/bench_cli" MIX_DEPS_PATH="_build/bench_deps" mix deps.get ) || { echo "deps.get failed for $TARGET" >&2; exit 65; }
  ( cd "$WORK_DIR" && MUTALISK_PATH="$ROOT" MIX_ENV=test MIX_BUILD_PATH="_build/bench_cli" MIX_DEPS_PATH="_build/bench_deps" mix compile ) >/dev/null 2>&1 || echo "WARN: compile emitted errors/warnings for $TARGET (continuing)" >&2
  touch "$WORK_DIR/.shard_ready"
fi

surface_flag() {
  case "$1" in
    nc)  echo "conditional negate_conditional";;
    sd)  echo "statement_delete statement_delete";;
    cd)  echo "clause_delete clause_delete";;
    gb)  echo "guard_boolean guard_boolean";;
    pd)  echo "pipeline_drop pipeline_drop_stage";;
    mu)  echo "map_update_drop map_update_drop";;
    rt)  echo "receive_timeout receive_timeout";;
    fr)  echo "dispatch function_replace";;
    pin) echo "pattern_shape pin";;
    *) echo "";;
  esac
}

# mut writes --output-path relative to the work_copy cwd; ensure the dir exists.
mkdir -p "$WORK_DIR/bench/results"

IFS=',' read -ra SURFACE_LIST <<< "$SURFACES"
for sk in "${SURFACE_LIST[@]}"; do
  spec="$(surface_flag "$sk")"
  [ -n "$spec" ] || { echo "skip unknown surface key: $sk" >&2; continue; }
  read -r ENABLE MUT <<< "$spec"

  REPORT="bench/results/$TARGET.$sk.stryker.json"
  echo "=== $TARGET / $sk ($ENABLE / $MUT) ==="
  rm -f "$WORK_DIR/$REPORT"

  ( cd "$WORK_DIR" && \
    MUTALISK_PATH="$ROOT" MIX_ENV=test MIX_BUILD_PATH="_build/bench_cli" MIX_DEPS_PATH="_build/bench_deps" \
    timeout 900 mix mut --fail-at 0 --selection "$SELECTION" --concurrency 1 \
      --enable "$ENABLE" --mutators "$MUT" --max-mutants "$MAX_MUTANTS" \
      --output-path "$REPORT" ) >"$RESULTS_DIR/$TARGET.$sk.terminal.txt" 2>&1
  rc=$?

  if [ "$rc" -ne 0 ] || [ ! -f "$WORK_DIR/$REPORT" ]; then
    echo "$TARGET $sk RUN_FAILED rc=$rc (see $TARGET.$sk.terminal.txt)" | tee -a "$RESULTS_DIR/summary.txt"
    continue
  fi

  cp "$WORK_DIR/$REPORT" "$RESULTS_DIR/$TARGET.$sk.stryker.json"

  ROOT="$ROOT" REPORT_PATH="$RESULTS_DIR/$TARGET.$sk.stryker.json" TARGET="$TARGET" SK="$sk" elixir --eval '
report = System.fetch_env!("REPORT_PATH") |> File.read!() |> JSON.decode!()
mutants = report["files"] |> Map.values() |> Enum.flat_map(& &1["mutants"])
n = length(mutants)
b = Enum.frequencies_by(mutants, & &1["status"])
killed = Map.get(b, "Killed", 0)
surv = Map.get(b, "Survived", 0)
covsurv = mutants |> Enum.filter(&(&1["status"] == "Survived" and length(&1["coveredBy"] || []) > 0)) |> length()
inv = Map.get(b, "CompileError", 0)
err = Map.get(b, "RuntimeError", 0)
tmo = Map.get(b, "Timeout", 0)
denom = killed + surv
kp = if denom == 0, do: 0.0, else: Float.round(killed/denom*100, 1)
eq = if denom == 0, do: 0.0, else: Float.round(covsurv/denom*100, 1)
ip = if n == 0, do: 0.0, else: Float.round(inv/n*100, 1)
line = "#{System.fetch_env!("TARGET")} #{System.fetch_env!("SK")} n=#{n} killed=#{killed} surv=#{surv} cov-surv=#{covsurv} kill%=#{kp} equiv%=#{eq} inv%=#{ip} err=#{err} tmo=#{tmo}"
IO.puts(line)
File.write!(System.fetch_env!("ROOT") <> "/bench/results/matrix/summary.txt", line <> "\n", [:append])
'
done

echo "shard done: $TARGET"
