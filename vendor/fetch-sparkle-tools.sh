#!/usr/bin/env bash
# Downloads the Sparkle release tools (generate_keys, sign_update, generate_appcast)
# into vendor/sparkle/bin. The framework itself comes through SwiftPM; these
# command-line tools only ship in the release archive.
set -euo pipefail
VERSION="${SPARKLE_VERSION:-2.10.0}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$ROOT/vendor/sparkle"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
curl -fsSL "https://github.com/sparkle-project/Sparkle/releases/download/$VERSION/Sparkle-$VERSION.tar.xz" -o "$TMP/sparkle.tar.xz"
mkdir -p "$TMP/x" && tar -xJf "$TMP/sparkle.tar.xz" -C "$TMP/x"
rm -rf "$DEST/bin" && mkdir -p "$DEST/bin"
cp "$TMP/x/bin/generate_keys" "$TMP/x/bin/sign_update" "$TMP/x/bin/generate_appcast" "$DEST/bin/"
echo "$VERSION" > "$DEST/VERSION"
echo "Sparkle $VERSION tools in $DEST/bin"
