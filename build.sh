#!/bin/sh
# Builds "Claude Whisper.app" into ./build. Options:
#   --install    copy it to ~/Applications and start it
#   --universal  build for Apple silicon and Intel (what the GitHub release ships)
# Signs with your Apple Development certificate when there is one, so macOS keeps the
# Accessibility, Input Monitoring and Microphone permissions across rebuilds; otherwise ad hoc.
set -e
cd "$(dirname "$0")"
NAME="Claude Whisper"
EXE=ClaudeWhisper
APP="build/$NAME.app"
INSTALL=false
ARCHS=arm64
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=true ;;
    --universal) ARCHS="arm64 x86_64" ;;
    *) echo "unknown option $arg" >&2; exit 2 ;;
  esac
done

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
SLICES=""
for arch in $ARCHS; do
  swiftc -O -swift-version 5 -target "$arch-apple-macos14" Sources/*.swift -o "build/$EXE-$arch"
  SLICES="$SLICES build/$EXE-$arch"
done
lipo -create $SLICES -output "$APP/Contents/MacOS/$EXE"
rm -f $SLICES
cp Resources/Info.plist "$APP/Contents/"
cp Resources/*.wav Resources/AppIcon.icns Resources/Assets.car Resources/claude-whisper-capture "$APP/Contents/Resources/"

IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/{print $2; exit}')
codesign --force --deep --sign "${IDENTITY:--}" "$APP"
echo "Built $APP ($ARCHS, signed with ${IDENTITY:-ad-hoc identity})"

if $INSTALL; then
  pkill -x "$EXE" 2>/dev/null && sleep 1 || true
  rm -rf "$HOME/Applications/$NAME.app"
  mkdir -p "$HOME/Applications"
  cp -R "$APP" "$HOME/Applications/"
  open "$HOME/Applications/$NAME.app"
  echo "Installed and started ~/Applications/$NAME.app"
fi
