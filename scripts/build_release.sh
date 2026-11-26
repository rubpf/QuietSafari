#!/bin/bash
# Ad-hoc Release build for people who will not open Xcode.
# Personal Team builds keep using the App Group entitlements. This script
# swaps in the ad-hoc entitlement files, which share a home folder instead.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DERIVED="$ROOT/build/DerivedData"
DIST="$ROOT/dist"
APP="$DERIVED/Build/Products/Release/QuietSafari.app"

rm -rf "$DIST"
mkdir -p "$DIST"

xcodebuild \
  -project QuietSafari.xcodeproj \
  -scheme QuietSafari \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -derivedDataPath "$DERIVED" \
  CODE_SIGN_STYLE=Manual \
  "CODE_SIGN_IDENTITY=-" \
  CODE_SIGNING_REQUIRED=YES \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  DEVELOPMENT_TEAM= \
  QUIETSAFARI_APP_ENTITLEMENTS="App/QuietSafariAdHoc.entitlements" \
  QUIETSAFARI_EXTENSION_ENTITLEMENTS="Extension/QuietSafariExtensionAdHoc.entitlements" \
  QUIETSAFARI_BLOCKER_ENTITLEMENTS="ContentBlocker/QuietSafariBlockerAdHoc.entitlements" \
  build

for plugin in QuietSafariExtension QuietSafariContentBlocker QuietSafariPrivacy QuietSafariRussian; do
  if [[ ! -d "$APP/Contents/PlugIns/${plugin}.appex" ]]; then
    echo "missing embedded extension: ${plugin}.appex" >&2
    exit 1
  fi
done

codesign --verify --deep "$APP"
ditto -c -k --keepParent "$APP" "$DIST/QuietSafari.zip"

STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/QuietSafari.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname QuietSafari -srcfolder "$STAGE" -ov -format UDZO "$DIST/QuietSafari.dmg"
rm -rf "$STAGE"

(
  cd "$DIST"
  shasum -a 256 QuietSafari.zip QuietSafari.dmg
) | tee "$DIST/SHA256SUMS.txt"

echo "release artifacts are in $DIST"
