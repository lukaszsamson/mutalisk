#!/usr/bin/env bash
# usage: biq_gate.sh <target: demo_app|jason|...> <label> [extra mix mut args...]
# Copies the target project, injects the mutalisk path dep, runs --debug-plan
# with two flag sets (default, env) and stores <S>/biq/<target>.<label>.{default,env}.json
set -euo pipefail
S=${BIQ_DIR:-/tmp/biq_gate}
MUT=${MUTALISK_PATH:-/Users/lukaszsamson/claude_fun/mutalisk}
T=$1; L=$2; shift 2
mkdir -p $S/biq
if [ "$T" = demo_app ]; then SRC=$MUT/test/fixtures/demo_app; else SRC=/Users/lukaszsamson/claude_fun/elixir_oss/projects/$T; fi
W=$S/biq/work_${T}_${L}
rm -rf "$W"; cp -R "$SRC" "$W"; cd "$W"; rm -rf _build deps plan.debug.json
if [ "$T" != demo_app ]; then
  perl -0pi -e 's/((?:def|defp) deps(?:\(\))? do\s*\[)/$1\n  {:mutalisk, path: System.fetch_env!("MUTALISK_PATH"), only: [:test], runtime: true},/s' mix.exs
fi
export MUTALISK_PATH=$MUT MIX_ENV=test
run() { # name, targets
  local name=$1; local targets=$2
  mix mut --debug-plan --enable "$targets" >/dev/null 2>$S/biq/$T.$L.$name.log || true
  cp plan.debug.json $S/biq/$T.$L.$name.json
  rm -f plan.debug.json
}
mix deps.get >/dev/null 2>&1 || true
run default "dispatch,guard,module_attribute,body_literal"
run env "dispatch,guard,module_attribute,body_literal,env_walker"
echo "done $T $L"
