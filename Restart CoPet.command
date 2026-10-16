#!/bin/bash
cd "$(dirname "$0")"
killall CoPet 2>/dev/null || true
sleep 0.5
APP="$(pwd)/build/CoPet.app"
if [[ ! -x "$APP/Contents/MacOS/CoPet" ]]; then
  echo "Missing $APP — run ./build.sh first"
  read -r _
  exit 1
fi
xattr -cr "$APP" 2>/dev/null || true
# Prefer direct binary if `open` is broken on this Mac
if ! open "$APP" 2>/dev/null; then
  exec "$APP/Contents/MacOS/CoPet"
fi
