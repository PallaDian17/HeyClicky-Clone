#!/usr/bin/env bash
# Cuts a Sparkle release: release build → zip → EdDSA signature → appcast.
#   APP_VERSION=0.2.0 scripts/release.sh [notes.html]
# Output: releases/HeyClickyClone-<version>.zip (not committed; attach it to a
# GitHub Release) and releases/appcast.xml (committed; SUFeedURL points at it).
# Needs vendor/sparkle/bin (vendor/fetch-sparkle-tools.sh) and the private key
# that `generate_keys --account HeyClickyClone` stored in the login Keychain.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${APP_VERSION:?set APP_VERSION, e.g. 0.2.0}"
OUT="${RELEASES_DIR:-$ROOT/releases}"
DOWNLOAD_BASE="${DOWNLOAD_BASE:-https://github.com/PallaDian17/HeyClicky-Clone/releases/download/v$VERSION}"
TOOLS="$ROOT/vendor/sparkle/bin"
[[ -x "$TOOLS/generate_appcast" ]] || { echo "run vendor/fetch-sparkle-tools.sh first" >&2; exit 1; }

APP_VERSION="$VERSION" "$ROOT/scripts/build-app.sh" release
mkdir -p "$OUT"
ZIP="$OUT/HeyClickyClone-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$ROOT/build/HeyClickyClone.app" "$ZIP"

# generate_appcast signs every archive in the folder and (re)writes appcast.xml,
# keeping older entries. Release notes: a sibling HeyClickyClone-<version>.html.
if [[ -n "${1:-}" ]]; then cp "$1" "$OUT/HeyClickyClone-$VERSION.html"; fi
# Signing key: SPARKLE_ED_KEY_FILE (exported with `generate_keys -x`) for unattended
# runs, otherwise the login-Keychain item generate_keys created.
if [[ -n "${SPARKLE_ED_KEY_FILE:-}" ]]; then
  KEY_ARGS=(--ed-key-file "$SPARKLE_ED_KEY_FILE")
else
  KEY_ARGS=(--account HeyClickyClone)
fi
"$TOOLS/generate_appcast" "${KEY_ARGS[@]}" --download-url-prefix "$DOWNLOAD_BASE/" --maximum-versions 5 "$OUT"
echo "Release $VERSION: $ZIP + $OUT/appcast.xml"
