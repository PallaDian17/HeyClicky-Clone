#!/usr/bin/env bash
# Builds the Swift package and assembles "build/Hi Dicky.app" (executable HeyClickyClone,
# bundle id com.ashish.heyclickyclone: those stay so TCC grants and data survive the rename).
# Usage: scripts/build-app.sh [debug|release]   (default: debug)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-debug}"
APP_NAME="HeyClickyClone"
BUNDLE_NAME="${BUNDLE_NAME:-Hi Dicky}"
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
# Sparkle: the appcast lives in releases/ on main (make the repo or a releases
# repo public for raw.githubusercontent.com to serve it). The EdDSA public key
# pairs with the private key `generate_keys --account HeyClickyClone` put in the
# login Keychain; the key itself is public and safe to commit.
SPARKLE_FEED_URL="${SPARKLE_FEED_URL:-https://raw.githubusercontent.com/PallaDian17/HeyClicky-Clone/main/releases/appcast.xml}"
SPARKLE_PUBLIC_KEY="${SPARKLE_PUBLIC_KEY:-uAUo9w5XtLfwjIWsfydXl2kmCjO00s9UByJ+/wd/QEM=}"
SENTRY_DSN="${SENTRY_DSN:-}"

cd "$ROOT"
swift build -c "$CONFIG" --product "$APP_NAME"

BIN="$(swift build -c "$CONFIG" --show-bin-path)/$APP_NAME"
APP="$ROOT/build/$BUNDLE_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"

# Vendored cua-driver (vendor/fetch-cua-driver.sh): the computer-use daemon the
# app spawns in embedded mode, plus the agent skill docs installed per Clicky.
if [[ -x "$ROOT/vendor/cua/bin/cua-driver" ]]; then
  mkdir -p "$APP/Contents/Helpers/cua" "$APP/Contents/Resources/cua-skill"
  # Only code may live under Helpers/ (codesign validates every file there as a
  # nested code object), so the version stamp goes with the skill docs.
  cp -R "$ROOT/vendor/cua/bin/." "$APP/Contents/Helpers/cua/"
  cp "$ROOT/vendor/cua/skill/"*.md "$APP/Contents/Resources/cua-skill/"
  cp "$ROOT/vendor/cua/VERSION" "$APP/Contents/Resources/cua-skill/VERSION"
else
  echo "warning: vendor/cua/bin/cua-driver missing; run vendor/fetch-cua-driver.sh (computer use disabled)" >&2
fi

# Starter Clickys founded on first launch, and the bundled power-up skills.
cp "$ROOT/apps/mac/Bundle/starter-agents.json" "$APP/Contents/Resources/starter-agents.json"
cp -R "$ROOT/apps/mac/Bundle/skills" "$APP/Contents/Resources/skills"

# Binary frameworks from SwiftPM artifacts (Sparkle, Sentry) ride in Contents/Frameworks.
ARTIFACTS="$ROOT/.build/artifacts"
mkdir -p "$APP/Contents/Frameworks"
for fw in "$ARTIFACTS/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" \
          "$ARTIFACTS/sentry-cocoa/Sentry-Dynamic/Sentry-Dynamic.xcframework/macos-arm64_x86_64/Sentry.framework"; do
  if [[ -d "$fw" ]] && otool -L "$APP/Contents/MacOS/$APP_NAME" | grep -q "$(basename "$fw" .framework).framework"; then
    rm -rf "$APP/Contents/Frameworks/$(basename "$fw")"
    cp -R "$fw" "$APP/Contents/Frameworks/"
  fi
done
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/$APP_NAME" 2>/dev/null || true

# SwiftPM resource bundles, if any target declares resources.
for b in "$(dirname "$BIN")"/*.bundle; do
  [[ -d "$b" ]] && cp -R "$b" "$APP/Contents/Resources/"
done

sed -e "s|__VERSION__|$VERSION|" \
    -e "s|__BUILD__|$BUILD_NUMBER|" \
    -e "s|__SUPABASE_URL__|$SUPABASE_URL|" \
    -e "s|__SUPABASE_ANON_KEY__|$SUPABASE_ANON_KEY|" \
    -e "s|__BACKEND_URL__|$BACKEND_URL|" \
    -e "s|__SPARKLE_FEED_URL__|$SPARKLE_FEED_URL|" \
    -e "s|__SPARKLE_PUBLIC_KEY__|$SPARKLE_PUBLIC_KEY|" \
    -e "s|__SENTRY_DSN__|$SENTRY_DSN|" \
    "$ROOT/apps/mac/Bundle/Info.plist" > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc signature. Note: macOS keys TCC grants (Accessibility, Screen Recording…)
# to the code signature, so an ad-hoc build may re-prompt after every rebuild.
# For day-to-day development create a self-signed "Code Signing" certificate in
# Keychain Access and export CODESIGN_IDENTITY="<its name>".
IDENTITY="${CODESIGN_IDENTITY:--}"
# Nested code first (Sparkle's XPC services + Autoupdate, Sentry), then the app.
for fw in "$APP/Contents/Frameworks"/*.framework; do
  [[ -d "$fw" ]] || continue
  find "$fw" \( -name "*.xpc" -o -name "*.app" \) -type d -print0 | while IFS= read -r -d '' nested; do
    codesign --force --sign "$IDENTITY" --options runtime "$nested" 2>/dev/null || codesign --force --sign "$IDENTITY" "$nested"
  done
  codesign --force --sign "$IDENTITY" "$fw"
done
codesign --force --sign "$IDENTITY" \
  --entitlements "$ROOT/apps/mac/Bundle/Entitlements.plist" \
  "$APP"

echo "Built $APP ($CONFIG, v$VERSION build $BUILD_NUMBER)"
