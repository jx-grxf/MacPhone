#!/usr/bin/env bash
# Submit dist/MacPhone-<version>.dmg for Apple notarization and staple the ticket.
#
# This is a no-op when MACPHONE_NOTARY_ENABLED != "true" so the default ad-hoc
# preview release pipeline does not require Apple credentials.
#
# Inputs (env):
#   MACPHONE_VERSION                    required
#   MACPHONE_UPDATE_CHANNEL             stable or beta
#   MACPHONE_NOTARY_ENABLED             "true" to actually submit, anything else skips
#   MACPHONE_NOTARY_APPLE_ID            Apple ID email
#   MACPHONE_NOTARY_TEAM_ID             Developer Team ID (10-char)
#   MACPHONE_NOTARY_PASSWORD            App-specific password
#   MACPHONE_NOTARY_KEYCHAIN_PROFILE    optional, prefer this if set
set -euo pipefail

cd "$(dirname "$0")/.."

: "${MACPHONE_VERSION:?MACPHONE_VERSION is required}"
CHANNEL="${MACPHONE_UPDATE_CHANNEL:-stable}"

if [[ "${MACPHONE_NOTARY_ENABLED:-}" != "true" ]]; then
  echo "Notarization skipped (MACPHONE_NOTARY_ENABLED != true; ad-hoc developer preview)"
  exit 0
fi

DMG="dist/MacPhone-${MACPHONE_VERSION}.dmg"
[[ -f "$DMG" ]] || { echo "error: $DMG not found" >&2; exit 1; }

if [[ -n "${MACPHONE_NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
  xcrun notarytool submit "$DMG" \
    --keychain-profile "$MACPHONE_NOTARY_KEYCHAIN_PROFILE" \
    --wait
else
  : "${MACPHONE_NOTARY_APPLE_ID:?required}"
  : "${MACPHONE_NOTARY_TEAM_ID:?required}"
  : "${MACPHONE_NOTARY_PASSWORD:?required}"
  xcrun notarytool submit "$DMG" \
    --apple-id "$MACPHONE_NOTARY_APPLE_ID" \
    --team-id "$MACPHONE_NOTARY_TEAM_ID" \
    --password "$MACPHONE_NOTARY_PASSWORD" \
    --wait
fi

xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

if [[ "$CHANNEL" == "stable" ]]; then
  codesign --verify --deep --strict dist/MacPhone.app
  spctl --assess --type execute -v dist/MacPhone.app
  spctl --assess --type open --context context:primary-signature -v "$DMG"
fi
