#!/bin/zsh
# Build, sign and install Kunyu to ~/Applications, then (re)launch it.
# Signing with a stable identity keeps Accessibility/Microphone grants across rebuilds.
#   ./build.sh               build + install + launch
#   ./build.sh --no-launch   build + install only
#   ./build.sh --icon        regenerate Resources/AppIcon.icns first
set -euo pipefail
cd "${0:A:h}"

IDENTITY="${IDENTITY:-Apple Development}"
BUILD=build/Kunyu.app
DEST="$HOME/Applications/Kunyu.app"

if [[ " $* " == *" --icon "* || ! -f Resources/AppIcon.icns ]]; then
  ICONSET=build/AppIcon.iconset
  rm -rf "$ICONSET" && mkdir -p "$ICONSET" Resources
  swift tools/make_icon.swift build/icon-1024.png
  for px in 16 32 128 256 512; do
    sips -z $px $px build/icon-1024.png --out "$ICONSET/icon_${px}x${px}.png" >/dev/null
    sips -z $((px * 2)) $((px * 2)) build/icon-1024.png --out "$ICONSET/icon_${px}x${px}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
fi

rm -rf "$BUILD"
mkdir -p "$BUILD/Contents/MacOS" "$BUILD/Contents/Resources"
# Universal binary: Intel + Apple Silicon.
for arch in x86_64 arm64; do
  swiftc -swift-version 5 -O -target $arch-apple-macosx13.0 -o build/Kunyu-$arch Sources/main.swift
done
lipo -create build/Kunyu-x86_64 build/Kunyu-arm64 -output "$BUILD/Contents/MacOS/Kunyu"
cp Info.plist "$BUILD/Contents/Info.plist"
cp Resources/AppIcon.icns "$BUILD/Contents/Resources/"
codesign --force --sign "$IDENTITY" "$BUILD"

pkill -x Kunyu 2>/dev/null || true
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R "$BUILD" "$DEST"
[[ " $* " == *" --no-launch "* ]] || open "$DEST"
echo "Installed $DEST"
