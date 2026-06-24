#!/usr/bin/env bash
# Validate every distributable before publishing and write SHA256SUMS.
set -euo pipefail

cd "$(dirname "$0")/.."

: "${MACPHONE_VERSION:?MACPHONE_VERSION is required}"
: "${MACPHONE_BUILD:?MACPHONE_BUILD is required}"
: "${MACPHONE_UPDATE_CHANNEL:?MACPHONE_UPDATE_CHANNEL is required}"
: "${MACPHONE_RELEASE_TAG:?MACPHONE_RELEASE_TAG is required}"

APP="dist/MacPhone.app"
DMG="dist/MacPhone-${MACPHONE_VERSION}.dmg"
ZIP="dist/sparkle/MacPhone-${MACPHONE_VERSION}.zip"
APPCAST="dist/sparkle/appcast.xml"

for path in "$APP" "$DMG" "$ZIP" "$APPCAST"; do
  [[ -e "$path" ]] || { echo "error: release artifact missing: $path" >&2; exit 1; }
done

INFO="$APP/Contents/Info.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO")" == "dev.johannesgrof.MacPhone" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO")" == "$MACPHONE_VERSION" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO")" == "$MACPHONE_BUILD" ]]
[[ -n "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$INFO")" ]]
[[ -f "$APP/Contents/Resources/AppIcon.icns" ]]
[[ -f "$APP/Contents/Resources/bridge/macphone_netsim_bridge.py" ]]
[[ ! -e "$APP/Contents/Resources/bridge/.venv" ]]

codesign --verify --deep --strict "$APP"
lipo -archs "$APP/Contents/MacOS/MacPhone" | grep -qw arm64
hdiutil imageinfo "$DMG" >/dev/null
unzip -tq "$ZIP" >/dev/null

./script/verify_appcast.swift \
  "$APPCAST" \
  "https://github.com/${GITHUB_REPOSITORY:-jx-grxf/MacPhone}/releases/download/${MACPHONE_RELEASE_TAG}/MacPhone-${MACPHONE_VERSION}.zip" \
  "$MACPHONE_UPDATE_CHANNEL" \
  "$MACPHONE_VERSION" \
  "$MACPHONE_BUILD" \
  "$ZIP"

if [[ "${MACPHONE_NOTARY_ENABLED:-}" == "true" ]]; then
  xcrun stapler validate "$DMG"
fi

(
  cd dist
  shasum -a 256 "MacPhone-${MACPHONE_VERSION}.dmg"
  shasum -a 256 "sparkle/MacPhone-${MACPHONE_VERSION}.zip" \
    | sed 's#  sparkle/#  #'
  shasum -a 256 "sparkle/appcast.xml" \
    | sed 's#  sparkle/#  #'
) > dist/SHA256SUMS

echo "release artifacts ok"
