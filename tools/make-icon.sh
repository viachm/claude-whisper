#!/bin/sh
# Rebuilds Resources/AppIcon.icns and Resources/Assets.car from tools/make-icon.swift.
# Assets.car is what macOS 26 reads (CFBundleIconName); it needs Xcode's actool. The .icns is
# the fallback for older macOS. Both are committed, so building Claude Whisper does not need Xcode.
set -e
cd "$(dirname "$0")/.."
T=$(mktemp -d)
swiftc -O tools/make-icon.swift -o "$T/make-icon"
"$T/make-icon" Resources/AppIcon.icns
iconutil -c iconset Resources/AppIcon.icns -o "$T/AppIcon.iconset"
X="$T/Assets.xcassets/AppIcon.appiconset"
mkdir -p "$X" "$T/out"
cp "$T"/AppIcon.iconset/*.png "$X/"
printf '{"info":{"version":1,"author":"xcode"}}' > "$T/Assets.xcassets/Contents.json"
{
  printf '{"images":['
  sep=""
  for base in 16 32 128 256 512; do
    printf '%s{"idiom":"mac","size":"%sx%s","scale":"1x","filename":"icon_%sx%s.png"}' "$sep" $base $base $base $base
    printf ',{"idiom":"mac","size":"%sx%s","scale":"2x","filename":"icon_%sx%s@2x.png"}' $base $base $base $base
    sep=","
  done
  printf '],"info":{"version":1,"author":"xcode"}}'
} > "$X/Contents.json"
xcrun actool "$T/Assets.xcassets" --compile "$T/out" --platform macosx --minimum-deployment-target 14.0 \
  --app-icon AppIcon --output-partial-info-plist "$T/partial.plist" >/dev/null
cp "$T/out/Assets.car" Resources/
rm -rf "$T"
echo "wrote Resources/AppIcon.icns and Resources/Assets.car"
