#!/bin/zsh
# Build Kunyu and publish it as a GitHub release (tag v<version from Info.plist>).
set -euo pipefail
cd "${0:A:h}"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)
./build.sh --no-launch
rm -f build/Kunyu.zip
ditto -c -k --keepParent build/Kunyu.app build/Kunyu.zip
gh release create "v$VERSION" build/Kunyu.zip --title "Kunyu $VERSION" \
  --notes "Universal (Apple Silicon + Intel), macOS 13+. Not notarized: on first launch use System Settings → Privacy & Security → Open Anyway. See the README for setup."
