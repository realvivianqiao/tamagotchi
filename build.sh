#!/bin/bash
# Builds build/CoPet.app (universal) with Sparkle, publishes zip + appcast.
# Run: ./build.sh && open build/CoPet.app
set -euo pipefail
cd "$(dirname "$0")"

./scripts/fetch-sparkle.sh

APP=build/CoPet.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
MIN=13.0
SPARKLE_FLAGS=(-F vendor -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks)
SRCS="main.swift Sprites.swift PetLines.swift PetView.swift Pet.swift Online.swift FriendVisitor.swift PetPicker.swift Updater.swift Ambient.swift BeatTracker.swift SpotifyTap.swift SpotifyDance.swift"

swiftc -O -swift-version 5 -target "arm64-apple-macosx${MIN}" \
  "${SPARKLE_FLAGS[@]}" $SRCS -o /tmp/CoPet-arm64
swiftc -O -swift-version 5 -target "x86_64-apple-macosx${MIN}" \
  "${SPARKLE_FLAGS[@]}" $SRCS -o /tmp/CoPet-x86_64
lipo -create /tmp/CoPet-arm64 /tmp/CoPet-x86_64 -output "$APP/Contents/MacOS/CoPet"
cp Info.plist "$APP/Contents/Info.plist"

# Embed Sparkle
rm -rf "$APP/Contents/Frameworks/Sparkle.framework"
cp -R vendor/Sparkle.framework "$APP/Contents/Frameworks/"

# App icon = in-app dog sprite → .icns (pixel-perfect at every size)
swiftc -O -swift-version 5 -target "arm64-apple-macosx${MIN}" \
  MakeIcon.swift Sprites.swift -o /tmp/CoPetMakeIcon
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
  /tmp/CoPetMakeIcon "$ICONSET/$name" "$px"
  flat_tmp="/tmp/CoPetIcon-${px}.jpg"
  sips -s format jpeg "$ICONSET/$name" --out "$flat_tmp" >/dev/null
  sips -s format png "$flat_tmp" --out "$FLATSET/$name" >/dev/null
done
if iconutil -c icns "$FLATSET" -o "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null; then
  :
elif [ -f "$APP/Contents/Resources/AppIcon.icns" ]; then
  :
else
  echo "warn: no AppIcon.icns (iconutil failed)" >&2
fi
/tmp/CoPetMakeIcon public/favicon.png 256
/tmp/CoPetMakeIcon public/app-icon.png 1024

codesign --force --deep --sign - "$APP"

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist 2>/dev/null || echo "0.0")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Info.plist 2>/dev/null || echo "0")
NOTES=${UPDATE_NOTES:-"Improvements and fixes."}
FEED_BASE=${FEED_BASE:-"https://tamagotchi-udtz.onrender.com"}

# Site download zip (also used by older custom updaters via version.json)
ditto -c -k --sequesterRsrc --keepParent "$APP" public/CoPet.zip
PUBLISHED=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
NOTES_JSON=$(UPDATE_NOTES="$NOTES" python3 -c 'import json,os; print(json.dumps(os.environ.get("UPDATE_NOTES","")))')
cat > public/version.json <<EOF
{
  "version": "${VERSION}",
  "url": "/CoPet.zip",
  "notes": ${NOTES_JSON},
  "publishedAt": "${PUBLISHED}"
}
EOF

# Sparkle appcast (EdDSA-signed). Requires secrets/sparkle_eddsa_private.key
KEY_FILE=secrets/sparkle_eddsa_private.key
if [[ -f "$KEY_FILE" ]]; then
  SIG_LINE=$(./vendor/bin/sign_update --ed-key-file "$KEY_FILE" public/CoPet.zip)
  # SIG_LINE looks like: sparkle:edSignature="..." length="..."
  python3 - "$SIG_LINE" "$VERSION" "$BUILD" "$NOTES" "$FEED_BASE" "$PUBLISHED" <<'PY'
import sys, html, pathlib
sig_line, version, build, notes, feed_base, published = sys.argv[1:7]
# Parse attributes from sign_update output
import re
m_sig = re.search(r'sparkle:edSignature="([^"]+)"', sig_line)
m_len = re.search(r'length="([^"]+)"', sig_line)
assert m_sig and m_len, sig_line
ed = m_sig.group(1)
length = m_len.group(1)
notes_esc = html.escape(notes)
xml = f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>CoPet</title>
    <link>{feed_base}/</link>
    <description>CoPet updates</description>
    <language>en</language>
    <item>
      <title>CoPet {version}</title>
      <pubDate>{published}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
      <description><![CDATA[{notes}]]></description>
      <enclosure
        url="{feed_base}/CoPet.zip"
        sparkle:edSignature="{ed}"
        length="{length}"
        type="application/octet-stream" />
    </item>
  </channel>
</rss>
"""
pathlib.Path("public/appcast.xml").write_text(xml)
print(f"Wrote public/appcast.xml (v{version} build {build}, {length} bytes)")
PY
else
  echo "warn: missing $KEY_FILE — skipped appcast signing (updates won't verify)" >&2
fi

echo "Built $APP (universal + Sparkle + ad-hoc signed)"
echo "Published public/CoPet.zip + public/version.json + public/appcast.xml (v${VERSION})"
