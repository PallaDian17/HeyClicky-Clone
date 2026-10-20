#!/usr/bin/env bash
# Builds the Swift package and assembles build/HeyClickyClone.app.
# Usage: scripts/build-app.sh [debug|release]   (default: debug)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-debug}"
APP_NAME="HeyClickyClone"
VERSION="${APP_VERSION:-0.1.0}"
BUILD_NUMBER="${APP_BUILD:-$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)}"

# Secrets for the bundle come from .env (gitignored) or the environment.
if [[ -f "$ROOT/.env" ]]; then
  set -a; # shellcheck disable=SC1091
  source "$ROOT/.env"; set +a
fi
SUPABASE_URL="${SUPABASE_URL:-}"
SUPABASE_ANON_KEY="${SUPABASE_ANON_KEY:-}"
BACKEND_URL="${BACKEND_URL:-http://localhost:8787}"

cd "$ROOT"
swift build -c "$CONFIG" --product "$APP_NAME"

BIN="$(swift build -c "$CONFIG" --show-bin-path)/$APP_NAME"
APP="$ROOT/build/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"

# SwiftPM resource bundles, if any target declares resources.
for b in "$(dirname "$BIN")"/*.bundle; do
  [[ -d "$b" ]] && cp -R "$b" "$APP/Contents/Resources/"
done

sed -e "s|__VERSION__|$VERSION|" \
    -e "s|__BUILD__|$BUILD_NUMBER|" \
    -e "s|__SUPABASE_URL__|$SUPABASE_URL|" \
    -e "s|__SUPABASE_ANON_KEY__|$SUPABASE_ANON_KEY|" \
    -e "s|__BACKEND_URL__|$BACKEND_URL|" \
    "$ROOT/apps/mac/Bundle/Info.plist" > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc signature. Note: macOS keys TCC grants (Accessibility, Screen Recording…)
# to the code signature, so an ad-hoc build may re-prompt after every rebuild.
# For day-to-day development create a self-signed "Code Signing" certificate in
# Keychain Access and export CODESIGN_IDENTITY="<its name>".
IDENTITY="${CODESIGN_IDENTITY:--}"
codesign --force --sign "$IDENTITY" \
  --entitlements "$ROOT/apps/mac/Bundle/Entitlements.plist" \
  "$APP"

echo "Built $APP ($CONFIG, v$VERSION build $BUILD_NUMBER)"
