#!/bin/bash
# Clears Gatekeeper quarantine on ad-hoc–signed CoPet (friends / coworkers).
cd "$(dirname "$0")"
APP="CoPet.app"
if [ ! -d "$APP" ]; then
  echo "Put this script next to CoPet.app and run it again."
  read -r _
  exit 1
fi
xattr -cr "$APP" 2>/dev/null
echo ""
echo "Cleared quarantine on $APP."
echo "If macOS still blocks it: System Settings → Privacy & Security → Open Anyway."
echo "Opening CoPet…"
open "$APP"
