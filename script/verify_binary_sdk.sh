#!/usr/bin/env bash
# Verify that the built executable is linked against the current macOS SDK.
set -euo pipefail

BINARY="${1:?usage: verify_binary_sdk.sh PATH_TO_EXECUTABLE}"
MIN_SDK_MAJOR="${MACPHONE_MIN_MACOS_SDK_MAJOR:-26}"

[[ -f "$BINARY" ]] || {
  echo "error: executable not found: $BINARY" >&2
  exit 1
}

BUILD_INFO="$(vtool -show-build "$BINARY")"
SDK_VERSION="$(awk '/^[[:space:]]+sdk / { print $2; exit }' <<<"$BUILD_INFO")"
SDK_MAJOR="${SDK_VERSION%%.*}"

if [[ -z "$SDK_VERSION" ]]; then
  echo "error: could not read linked SDK from $BINARY" >&2
  exit 1
fi

if [[ ! "$SDK_MAJOR" =~ ^[0-9]+$ || "$SDK_MAJOR" -lt "$MIN_SDK_MAJOR" ]]; then
  echo "error: $BINARY links macOS SDK $SDK_VERSION; SDK $MIN_SDK_MAJOR or newer is required" >&2
  exit 1
fi

echo "binary SDK ok: $SDK_VERSION ($BINARY)"
