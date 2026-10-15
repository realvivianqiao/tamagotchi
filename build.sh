#!/bin/bash
# Builds build/Mochi.app (universal). Run: open build/Mochi.app
set -euo pipefail
cd "$(dirname "$0")"
APP=build/Mochi.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
MIN=13.0
SRCS="main.swift Sprites.swift PetView.swift Pet.swift Online.swift FriendVisitor.swift PetPicker.swift"
swiftc -O -swift-version 5 -target "arm64-apple-macosx${MIN}" \
  $SRCS -o /tmp/Mochi-arm64
swiftc -O -swift-version 5 -target "x86_64-apple-macosx${MIN}" \
  $SRCS -o /tmp/Mochi-x86_64
lipo -create /tmp/Mochi-arm64 /tmp/Mochi-x86_64 -output "$APP/Contents/MacOS/Mochi"
cp Info.plist "$APP/Contents/Info.plist"

# App icon = in-app dog sprite → .icns (pixel-perfect at every size)
swiftc -O -swift-version 5 -target "arm64-apple-macosx${MIN}" \
  MakeIcon.swift Sprites.swift -o /tmp/MochiMakeIcon
ICONSET=build/AppIcon.iconset
FLATSET=build/AppIcon-flat.iconset
rm -rf "$ICONSET" "$FLATSET"
mkdir -p "$ICONSET" "$FLATSET"
# Build Apple iconset names without embedding "@2x" literals (tools rewrite those as emails).
AT2X=$(printf '@%s' '2x')
for pair in \
  "icon_16x16.png:16" \
  "icon_16x16${AT2X}.png:32" \
  "icon_32x32.png:32" \
  "icon_32x32${AT2X}.png:64" \
  "icon_128x128.png:128" \
  "icon_128x128${AT2X}.png:256" \
  "icon_256x256.png:256" \
  "icon_256x256${AT2X}.png:512" \
  "icon_512x512.png:512" \
  "icon_512x512${AT2X}.png:1024"
do
  name="${pair%%:*}"
  px="${pair##*:}"
  /tmp/MochiMakeIcon "$ICONSET/$name" "$px"
  # iconutil rejects CGImage RGBA PNGs — flatten via JPEG → PNG (opaque).
  # Temp jpg must not contain "@" (sips / tooling treat it like an email).
  flat_tmp="/tmp/MochiIcon-${px}.jpg"
  sips -s format jpeg "$ICONSET/$name" --out "$flat_tmp" >/dev/null
  sips -s format png "$flat_tmp" --out "$FLATSET/$name" >/dev/null
done
# Verify all 10 iconset slots exist before iconutil
ls "$FLATSET" | wc -l | grep -q 10
iconutil -c icns "$FLATSET" -o "$APP/Contents/Resources/AppIcon.icns"
# Site favicon + og-ish icon (same dog)
/tmp/MochiMakeIcon public/favicon.png 256
/tmp/MochiMakeIcon public/app-icon.png 1024

codesign --force --deep --sign - "$APP"
echo "Built $APP (universal + ad-hoc signed + dog icon)"
