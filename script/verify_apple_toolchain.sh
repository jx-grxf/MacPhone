#!/usr/bin/env bash
# Prevent CI and releases from silently falling back to an older Apple SDK.
set -euo pipefail

MIN_XCODE_MAJOR="${MACPHONE_MIN_XCODE_MAJOR:-26}"
MIN_SDK_MAJOR="${MACPHONE_MIN_MACOS_SDK_MAJOR:-26}"

XCODE_VERSION="$(xcodebuild -version | awk 'NR == 1 { print $2 }')"
XCODE_BUILD="$(xcodebuild -version | awk 'NR == 2 { print $3 }')"
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
DEVELOPER_PATH="$(xcode-select -p)"
OS_VERSION="$(sw_vers -productVersion)"

XCODE_MAJOR="${XCODE_VERSION%%.*}"
SDK_MAJOR="${SDK_VERSION%%.*}"

if [[ ! "$XCODE_MAJOR" =~ ^[0-9]+$ || "$XCODE_MAJOR" -lt "$MIN_XCODE_MAJOR" ]]; then
  echo "error: Xcode $MIN_XCODE_MAJOR or newer is required; active version is $XCODE_VERSION" >&2
  exit 1
fi

if [[ ! "$SDK_MAJOR" =~ ^[0-9]+$ || "$SDK_MAJOR" -lt "$MIN_SDK_MAJOR" ]]; then
  echo "error: macOS SDK $MIN_SDK_MAJOR or newer is required; active SDK is $SDK_VERSION" >&2
  exit 1
fi

echo "Apple toolchain ok: macOS $OS_VERSION, Xcode $XCODE_VERSION ($XCODE_BUILD), SDK $SDK_VERSION"
echo "Developer directory: $DEVELOPER_PATH"
