#!/usr/bin/env bash
# Runs every check CI runs that works without a C compiler. Stops at the
# first failure.
set -euo pipefail
cd "$(dirname "$0")/.."
moon check --target js --deny-warn
moon fmt --check
moon test --target js
moon test --target wasm-gc
moon build --target js
# Differential tests need the reference ninja: NINJA=/path/to/ninja.
if [ -n "${NINJA:-}" ]; then
  node scripts/difftest.mjs --ninja "$NINJA"
fi
