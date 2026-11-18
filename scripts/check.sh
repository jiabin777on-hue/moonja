#!/usr/bin/env bash
# Runs every check CI runs that works without a C compiler. Stops at the
# first failure.
set -euo pipefail
cd "$(dirname "$0")/.."
moon check --target js --deny-warn
moon fmt --check
moon test --target js
moon test --target wasm-gc
