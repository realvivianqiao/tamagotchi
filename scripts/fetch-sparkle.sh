#!/bin/bash
# Downloads Sparkle 2.10 into vendor/ (framework + signing tools).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VER=2.10.0
VENDOR="$ROOT/vendor"
mkdir -p "$VENDOR"
if [[ -d "$VENDOR/Sparkle.framework" && -x "$VENDOR/bin/generate_appcast" ]]; then
  echo "Sparkle already present in vendor/"
  exit 0
fi
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
curl -L "https://github.com/sparkle-project/Sparkle/releases/download/${VER}/Sparkle-${VER}.tar.xz" \
  -o "$TMP/Sparkle.tar.xz"
tar -xJf "$TMP/Sparkle.tar.xz" -C "$TMP"
# Layout from the tarball is flat into TMP
cp -R "$TMP/Sparkle.framework" "$VENDOR/"
mkdir -p "$VENDOR/bin"
cp "$TMP/bin/generate_appcast" "$TMP/bin/sign_update" "$TMP/bin/generate_keys" "$TMP/bin/BinaryDelta" "$VENDOR/bin/"
xattr -cr "$VENDOR/Sparkle.framework" "$VENDOR/bin" 2>/dev/null || true
echo "Fetched Sparkle ${VER} → vendor/"
