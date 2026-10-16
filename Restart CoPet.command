#!/bin/bash
# Install a non-quarantined CoPet and launch it (Downloads copies get App Translocation).
set -e
cd "$(dirname "$0")"
killall CoPet 2>/dev/null || true
sleep 0.4

SRC="$(pwd)/build/CoPet.app"
if [[ ! -x "$SRC/Contents/MacOS/CoPet" ]]; then
  echo "Missing $SRC — run ./build.sh first"
  read -r _
  exit 1
fi

# Strip quarantine so macOS won't run a disposable temp copy.
xattr -cr "$SRC" 2>/dev/null || true

mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/CoPet.app"
ditto "$SRC" "$HOME/Applications/CoPet.app"
xattr -cr "$HOME/Applications/CoPet.app" 2>/dev/null || true

# Desktop + Downloads: replace with clean copies (same binary, no Chrome quarantine).
for DEST in "$HOME/Desktop/CoPet.app" "$HOME/Downloads/CoPet.app"; do
  rm -rf "$DEST"
  ditto "$SRC" "$DEST"
  xattr -cr "$DEST" 2>/dev/null || true
done

LAUNCH="$HOME/Applications/CoPet.app"
# Prefer direct binary — more reliable than `open` for ad-hoc builds.
exec "$LAUNCH/Contents/MacOS/CoPet"
