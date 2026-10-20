#!/usr/bin/env bash
# Build (debug) and launch the app; logs go to the unified log (see scripts/logs.sh).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$ROOT/scripts/build-app.sh" "${1:-debug}"
pkill -x HeyClickyClone 2>/dev/null || true
open "$ROOT/build/HeyClickyClone.app"
