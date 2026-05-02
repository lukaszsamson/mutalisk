#!/usr/bin/env bash
# Sanity-run the fixture demo_app as a standalone Mix project.
# This catches "fixture broken" regressions independently of mutalisk's own
# unit tests, so a lint/unit failure isn't conflated with a fixture defect.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE="$ROOT/test/fixtures/demo_app"

if [ ! -d "$FIXTURE" ]; then
  echo "fixture missing: $FIXTURE" >&2
  exit 1
fi

cd "$FIXTURE"

# Fail loudly on deps fetch errors. The fixture is intentionally minimal and
# either has no deps (no-op) or has hex deps that should resolve cleanly. A
# failure here means the fixture is broken or the network is unavailable —
# either way, do not silently proceed.
mix deps.get
MIX_ENV=test mix test
