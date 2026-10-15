#!/bin/bash
# Builds build/Mochi.app (universal). Run: open build/Mochi.app
set -euo pipefail
cd "$(dirname "$0")"
APP=build/Mochi.app
mkdir -p "$APP/Contents/MacOS"
MIN=13.0
SRCS="main.swift Sprites.swift PetView.swift Pet.swift Online.swift FriendVisitor.swift PetPicker.swift"
swiftc -O -swift-version 5 -target "arm64-apple-macosx${MIN}" \
  $SRCS -o /tmp/Mochi-arm64
swiftc -O -swift-version 5 -target "x86_64-apple-macosx${MIN}" \
  $SRCS -o /tmp/Mochi-x86_64
lipo -create /tmp/Mochi-arm64 /tmp/Mochi-x86_64 -output "$APP/Contents/MacOS/Mochi"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP"
echo "Built $APP (universal + ad-hoc signed)"
