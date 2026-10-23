#!/usr/bin/env bash
# Brings the desktop app up to date with main: pull, build, quit the running
# app, launch the new one. Safe to run from a terminal or from Setup -> Updates.
#   scripts/update.sh [--no-pull] [--relaunch-pid <pid>]
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PULL=1; WAIT_PID=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-pull) PULL=0 ;;
    --relaunch-pid) WAIT_PID="$2"; shift ;;
  esac
  shift
done
cd "$ROOT"
echo "== $(date '+%H:%M:%S') update.sh in $ROOT"
if [[ $PULL -eq 1 ]]; then
  if [[ -n "$(git status --porcelain)" ]]; then
    echo "working tree has local changes; pulling with --autostash"
    git pull --rebase --autostash origin main
  else
    git pull --rebase origin main
  fi
fi
echo "== building $(git rev-parse --short=9 HEAD)"
scripts/build-app.sh
APP="$ROOT/build/Hi Dicky.app"
# Quit whatever is running (by bundle id, so the old name still works), then relaunch.
osascript -e 'tell application id "com.ashish.heyclickyclone" to quit' >/dev/null 2>&1 || true
if [[ -n "$WAIT_PID" ]]; then
  for _ in $(seq 1 50); do kill -0 "$WAIT_PID" 2>/dev/null || break; sleep 0.2; done
  kill -0 "$WAIT_PID" 2>/dev/null && kill "$WAIT_PID" 2>/dev/null || true
fi
sleep 0.5
open -g "$APP"
echo "== launched $(plutil -extract GitCommit raw "$APP/Contents/Info.plist") build $(plutil -extract CFBundleVersion raw "$APP/Contents/Info.plist")"
