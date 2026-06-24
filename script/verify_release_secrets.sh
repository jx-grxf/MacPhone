#!/usr/bin/env bash
# Fail before an expensive release build when required signing inputs are absent.
# Secret values are never printed.
set -euo pipefail

cd "$(dirname "$0")/.."

require_secret() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "error: required release secret $name is not configured" >&2
    return 1
  fi
}

fail=0
require_secret MACPHONE_SPARKLE_PRIVATE_KEY || fail=1
require_secret MACPHONE_SPARKLE_PUBLIC_KEY || fail=1

canonical_public_key="$(awk -F'"' '/MACPHONE_SPARKLE_PUBLIC_KEY:/ { print $2; exit }' project.yml)"
if [[ -n "${MACPHONE_SPARKLE_PUBLIC_KEY:-}" && "$MACPHONE_SPARKLE_PUBLIC_KEY" != "$canonical_public_key" ]]; then
  echo "error: MACPHONE_SPARKLE_PUBLIC_KEY does not match project.yml" >&2
  fail=1
fi

# Notarization is optional (ad-hoc preview by default). Only enforce the signing
# secrets when the maintainer has explicitly turned notarization on.
if [[ "${MACPHONE_NOTARY_ENABLED:-}" == "true" ]]; then
  require_secret MACPHONE_SIGN_IDENTITY || fail=1
  if [[ -z "${MACPHONE_NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
    require_secret MACPHONE_NOTARY_APPLE_ID || fail=1
    require_secret MACPHONE_NOTARY_TEAM_ID || fail=1
    require_secret MACPHONE_NOTARY_PASSWORD || fail=1
  fi
fi

if [[ "$fail" -ne 0 ]]; then
  exit 1
fi

echo "release secrets ok"
