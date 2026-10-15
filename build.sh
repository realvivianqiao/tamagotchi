#!/bin/bash
# Builds build/Mochi.app. Run it with: open build/Mochi.app
set -euo pipefail
cd "$(dirname "$0")"
APP=build/Mochi.app
mkdir -p "$APP/Contents/MacOS"
swiftc -O -swift-version 5 \
  main.swift Sprites.swift PetView.swift Pet.swift Online.swift Feed.swift \
  -o "$APP/Contents/MacOS/Mochi"
cp Info.plist "$APP/Contents/Info.plist"
echo "Built $APP"
