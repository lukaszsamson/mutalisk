#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="plug_crypto"
SELECTION="static"
CONCURRENCY="1"
WORKER_TYPE="mix"
ENABLE_BODY_LITERAL="0"

usage() {
  printf 'usage: bench/run.sh [--target decimal|plug_crypto|nimble_options|gettext|ecto|mox|jason|plug|phoenix_html|telemetry_metrics|mint|finch|ex_machina|nimble_pool|nimble_csv|phoenix_pubsub] [--selection static|coverage|coverage_with_static_fallback] [--concurrency N] [--worker-type mix|persistent] [--enable-body-literal]\n' >&2
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
  # M27 v1.11 OSS validation harness expansion. SHAs pinned to latest
  # stable tags queried 2026-05-10. The expansion targets ecosystem
  # shapes the M25 set did not cover: Phoenix-class compile macros
  # (phoenix_html), telemetry/metrics primitives (telemetry_metrics),
  # process-tree-heavy HTTP clients (mint, finch), and ExUnit factory
  # macros (ex_machina). See bench/M27_RUNBOOK.md for per-target prep.
  phoenix_html)
    REPO="https://github.com/phoenixframework/phoenix_html.git"
    REF="${BENCH_REF:-v4.3.0}"
    SHA="${BENCH_SHA:-8cfd3e37ff9ef0924812a78cf6c9d27cdbd4e726}"
    ;;
  telemetry_metrics)
    REPO="https://github.com/beam-telemetry/telemetry_metrics.git"
    REF="${BENCH_REF:-v1.1.0}"
    SHA="${BENCH_SHA:-138d5322aa004d1b207dee75860dc90ee9ad2601}"
    ;;
  mint)
    REPO="https://github.com/elixir-mint/mint.git"
    REF="${BENCH_REF:-v1.8.0}"
    SHA="${BENCH_SHA:-f697f1c866ee1e5c802d19142487a85ea9eb0174}"
    ;;
  finch)
    REPO="https://github.com/sneako/finch.git"
    REF="${BENCH_REF:-v0.9.1}"
    SHA="${BENCH_SHA:-0530e34d726b1efb1bae2518ea7c7751ea428f20}"
    ;;
  ex_machina)
    REPO="https://github.com/beam-community/ex_machina.git"
    REF="${BENCH_REF:-v2.8.0}"
    SHA="${BENCH_SHA:-d1ec5e4b5af19276e2f5c184a05aa849323ad9a3}"
    ;;
  # M27 secondary expansion: smaller candidates added once the first
  # round (phoenix_html, plug, finch, ex_machina) hit unrunnable
  # blockers. These cover process-tree primitives (nimble_pool,
  # phoenix_pubsub) and a CSV parser (nimble_csv) — none require
  # external infrastructure.
  nimble_pool)
    REPO="https://github.com/dashbitco/nimble_pool.git"
    REF="${BENCH_REF:-v1.1.0}"
    SHA="${BENCH_SHA:-9829f2753851694dd1b34682e0abede895966ca5}"
    ;;
  nimble_csv)
    REPO="https://github.com/dashbitco/nimble_csv.git"
    REF="${BENCH_REF:-v1.3.0}"
    SHA="${BENCH_SHA:-2fc3cbf4b50ec504aa4f8d7ab9109c06ec9a7173}"
    ;;
  phoenix_pubsub)
    REPO="https://github.com/phoenixframework/phoenix_pubsub.git"
    REF="${BENCH_REF:-v2.2.0}"
    SHA="${BENCH_SHA:-086e0af0af9306580ee59025c85931936a849ab5}"
    ;;
  # M27 tertiary expansion: pure-logic libraries selected to avoid
  # the HTML/escaped-quote SchemaPlacer crash that knocks out
  # phoenix_html / plug / phoenix_pubsub.
  castore)
    REPO="https://github.com/elixir-mint/castore.git"
    REF="${BENCH_REF:-v1.0.9}"
    SHA="${BENCH_SHA:-428328b630f7247a9eb2380792adda9d5e537673}"
    ;;
  mime)
    REPO="https://github.com/elixir-plug/mime.git"
    REF="${BENCH_REF:-v2.0.7}"
    SHA="${BENCH_SHA:-4bb1ba13040a13b2f5d71bede10a7e3e45fc8e93}"
    ;;
  gen_stage)
    REPO="https://github.com/elixir-lang/gen_stage.git"
    REF="${BENCH_REF:-v1.3.2}"
    SHA="${BENCH_SHA:-d1532fa56482bc92d90abc777439ff8be34b5b1a}"
    ;;
  tzdata)
    REPO="https://github.com/lau/tzdata.git"
    REF="${BENCH_REF:-v1.1.3}"
    SHA="${BENCH_SHA:-61fb7ecf68fb9a3dbf7aeb7669adc3d0f7360b33}"
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
# Some targets (e.g. plug v1.19.1) declare `def deps` rather than `defp
# deps`; match either form.
perl -0pi -e 's/((?:def|defp) deps(?:\(\))? do\s*\[)/$1\n      {:mutalisk, path: System.fetch_env!("MUTALISK_PATH"), only: [:test], runtime: true},/s' "$MIX_FILE"

# Per-target test-tree prep. Required because some upstream test suites
# fail against the current Elixir/Mix environment for reasons unrelated
# to mutation testing (env-fragile stdout assertions, DB-dependent tests,
# StreamData seed determinism). Document any exclusion here AND in
# BENCHMARKS so downstream readers know the kill-rate basis.
case "$TARGET" in
  gettext)
    # v1.0.2's mix.tasks.gettext.extract tests assert Mix's own stdout
    # formatting; output drifted in newer Mix versions. Drop the file
    # so baseline is green; mutation surface is unaffected (the task
    # itself remains compiled, just not test-asserted).
    rm -f "$WORK_DIR/test/mix/tasks/gettext.extract_test.exs"
    rm -f "$WORK_DIR/test/mix/tasks/gettext.merge_test.exs"
    ;;
  ecto)
    # Exclude DB-backed integration tests when no Postgres/MySQL is up.
    # Inject into the existing test_helper.exs (which loads Ecto.TestRepo
    # support file) rather than overwriting; preserves project setup.
    perl -pi -e 's/ExUnit\.start\(\)/ExUnit.start(exclude: [:integration, :postgres, :mysql, :elixir_19_regex_drift], seed: 42)/' "$WORK_DIR/test/test_helper.exs"

    # M25 follow-up: Elixir 1.19 changed Regex internals so ~r/x/ == ~r/x/
    # is now false (the re_pattern field carries a unique reference per
    # compile). v3.13.6's changeset_test.exs has 9 tests that assert
    # `constraints(changeset) == [%{constraint: ~r/.../}]`; they fail on
    # 1.19 but pass on <=1.18. Upstream master fixed this by switching to
    # pattern-match form, but the fix is bundled with non-bench-relevant
    # API changes (reorder_assoc, trim_values vs empty_values) so we don't
    # cherry-pick. Instead, tag the 9 tests with :elixir_19_regex_drift
    # and exclude the tag in test_helper.exs above. Mutation surface
    # (lib/ecto/changeset.ex) is unchanged; the killing-test denominator
    # shrinks by 9 of ~1500. Document any change to this list in
    # BENCHMARKS.md.
    perl -pi -e '
      BEGIN {
        @skip = (
          "fetch_change!/2",
          "validate_format/4",
          "check_constraint/3",
          "unique_constraint/3",
          "unique_constraint/3 on field with :source",
          "foreign_key_constraint/3",
          "assoc_constraint/3",
          "no_assoc_constraint/3",
          "exclusion_constraint/3"
        );
        $pat = join("|", map { quotemeta } @skip);
      }
      s/^(\s+)(test "(?:$pat)" do\b)/$1\@tag :elixir_19_regex_drift\n$1$2/;
    ' "$WORK_DIR/test/ecto/changeset_test.exs"
    ;;
  jason)
    # Pin StreamData seed for reproducibility across mix/persistent diffs.
    perl -pi -e 's/ExUnit\.start\(\)/ExUnit.start(seed: 42)/' "$WORK_DIR/test/test_helper.exs"
    ;;
  mint)
    # Mint's IntegrationTest modules expect a local httpbin / nghttp2.org
    # / proxy listeners. The integration_test.exs files aren't tagged,
    # so excluding by tag is insufficient — drop the files entirely so
    # the deterministic test surface remains apples-to-apples for
    # mix-vs-persistent comparison. Mutation surface (lib/) is
    # unchanged; documented in BENCHMARKS.md.
    rm -f "$WORK_DIR/test/mint/integration_test.exs"
    rm -f "$WORK_DIR/test/mint/http1/integration_test.exs"
    rm -f "$WORK_DIR/test/mint/http2/integration_test.exs"
    perl -pi -e 's/ExUnit\.start\((.*)\)/ExUnit.start(exclude: [:requires_internet, :integration, :proxy], seed: 42)/' "$WORK_DIR/test/test_helper.exs"
    ;;
  finch)
    # finch transitively depends on :x509 which fails to compile under
    # Erlang/OTP 28 (`no record AttributePKCS-10 found in PKCS-FRAME.hrl`).
    # Document as unrunnable for M27; revisit when x509 ships a 28-
    # compatible release. The harness still pins finch for future
    # operators on older OTP.
    printf 'finch is unrunnable on this OTP (x509 dep incompatibility); see BENCHMARKS.md\n' >&2
    exit 65
    ;;
  plug)
    # plug v1.19.1: ssl_test.exs creates fake keyfile paths
    # ("abcdef", "ghijkl") relative to `_build/test/lib/plug/`; under
    # Mutalisk's work-copy cwd these don't exist, producing 3
    # baseline failures unrelated to mutation. Drop the file — TLS
    # configuration isn't in plug's body-mutation surface (Plug.SSL
    # is mostly module attributes + dispatch, mostly unmutable).
    rm -f "$WORK_DIR/test/plug/ssl_test.exs"
    perl -pi -e 's/ExUnit\.start\((.*)\)/ExUnit.start(seed: 42)/' "$WORK_DIR/test/test_helper.exs"
    ;;
  phoenix_html|telemetry_metrics|nimble_pool|nimble_csv|castore|mime|gen_stage|tzdata)
    # Pin seed for reproducibility; no network or DB required.
    perl -pi -e 's/ExUnit\.start\((.*)\)/ExUnit.start(seed: 42)/' "$WORK_DIR/test/test_helper.exs"
    ;;
  phoenix_pubsub)
    # phoenix_pubsub v2.2.0 baseline shows 2 ETS-shape failures on
    # OTP 28 (`:ets.lookup_element/3` returns `{{:duplicate, :pid}, n, nil}`
    # rather than `{:duplicate, n, _}`). Tag-skip the two specific
    # tests so baseline is green; mutation surface (lib/) unchanged.
    perl -0pi -e '
      s/^(\s+)(test "PubSub pool size can be configured separately from the Registry partitions",)/$1\@tag :otp_28_ets_shape_drift\n$1$2/m;
      s/^(\s+)(test "Registry partitions are configured with the same pool size as PubSub if not specified",)/$1\@tag :otp_28_ets_shape_drift\n$1$2/m;
    ' "$WORK_DIR/test/shared/pubsub_test.exs"
    perl -pi -e 's/ExUnit\.start\((.*)\)/ExUnit.start(exclude: [:otp_28_ets_shape_drift], seed: 42)/' "$WORK_DIR/test/test_helper.exs"
    ;;
  ex_machina)
    # ex_machina's mix.exs lists :credo as a dev/test dep. Credo's
    # ConfigCommentFinder regex (~r/[a-z_]+:[\\s,)]/) is rejected by
    # Elixir 1.19's stricter character-class parser, blocking compile
    # of any project that pulls credo in test env. ex_machina at
    # v2.8.0 has no path to drop credo without forking; classify as
    # unrunnable on Elixir 1.19+. Pin remains for future operators on
    # 1.18 or with patched credo.
    printf 'ex_machina is unrunnable on Elixir 1.19+ (credo dep); see BENCHMARKS.md\n' >&2
    exit 65
    ;;
esac

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
report = System.fetch_env!("REPORT_PATH") |> File.read!() |> JSON.decode!()
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
