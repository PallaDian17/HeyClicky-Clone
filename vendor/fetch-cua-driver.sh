#!/usr/bin/env bash
# Downloads the pinned trycua cua-driver (MIT) universal macOS binary and its
# agent skill bundle into vendor/cua/, verifying SHA-256. The app bundles the
# driver under Contents/Helpers/cua/ and installs the skill into each agent.
set -euo pipefail

CUA_VERSION="0.37.0"
SHA_DRIVER="7d491f67f54be5f3b380ffd85c64b242eaefd05dad6df78012cde227c95aee2a"   # darwin-universal-binary.tar.gz
SHA_SKILLS="a438d189e7b90ff4e85c65d4da50afd754cd323148aba5dd7f4bacb3b72470a4"   # skills.tar.gz

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$ROOT/vendor/cua"
STAMP="$DEST/VERSION"

if [[ -x "$DEST/bin/cua-driver" && -f "$DEST/skill/SKILL.md" && -f "$STAMP" && "$(cat "$STAMP")" == "$CUA_VERSION" ]]; then
  echo "cua-driver $CUA_VERSION already vendored"
  exit 0
fi

BASE="https://github.com/trycua/cua/releases/download/cua-driver-rs-v$CUA_VERSION"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fetch() {   # fetch <asset> <sha256> <out>
  echo "downloading $BASE/$1"
  curl -fsSL -o "$3" "$BASE/$1"
  local actual; actual="$(shasum -a 256 "$3" | awk '{print $1}')"
  [[ "$actual" == "$2" ]] || { echo "sha256 mismatch for $1: $actual" >&2; exit 1; }
}

fetch "cua-driver-rs-$CUA_VERSION-darwin-universal-binary.tar.gz" "$SHA_DRIVER" "$TMP/driver.tar.gz"
fetch "cua-driver-rs-v$CUA_VERSION-skills.tar.gz" "$SHA_SKILLS" "$TMP/skills.tar.gz"

rm -rf "$DEST"
mkdir -p "$DEST/bin" "$DEST/skill" "$TMP/driver" "$TMP/skills"
tar -xzf "$TMP/driver.tar.gz" -C "$TMP/driver"
tar -xzf "$TMP/skills.tar.gz" -C "$TMP/skills"

# Binary, the SDK dylib it loads, and the cursor theme for the agent-cursor overlay.
cp "$TMP/driver/cua-driver" "$DEST/bin/"
cp "$TMP/driver/libcua_driver_sdk.dylib" "$DEST/bin/"
[[ -e "$TMP/driver/cua-cursor-theme" ]] && cp -R "$TMP/driver/cua-cursor-theme" "$DEST/bin/"
chmod +x "$DEST/bin/cua-driver"

# Skill docs: the agent reads SKILL.md + MACOS.md; other platforms are dropped.
SKILLDIR="$(find "$TMP/skills" -name SKILL.md -maxdepth 2 | head -1 | xargs dirname)"
for f in SKILL.md MACOS.md BROWSER.md WORKFLOW.md VISUAL.md RUNTIME.md README.md; do
  [[ -f "$SKILLDIR/$f" ]] && cp "$SKILLDIR/$f" "$DEST/skill/"
done

echo "$CUA_VERSION" > "$STAMP"
echo "vendored $("$DEST/bin/cua-driver" --version) + skill -> $DEST"
