#!/usr/bin/env bash
# Build the MacPhone Debug bundle and (optionally) launch it.
#
# Usage:
#   ./script/build_and_run.sh              # build + launch
#   ./script/build_and_run.sh build-only   # build, do not launch
set -euo pipefail

cd "$(dirname "$0")/.."

./script/prepare_xcode_project.sh

DERIVED_DATA="$(mktemp -d)"
trap 'rm -rf "$DERIVED_DATA"' EXIT

xcodebuild \
  -project MacPhone.xcodeproj \
  -scheme MacPhone \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  -onlyUsePackageVersionsFromResolvedFile \
  -skipPackageUpdates \
  build | tail -20

APP_PATH="$DERIVED_DATA/Build/Products/Debug/MacPhone.app"

if [[ ! -d "$APP_PATH" ]]; then
  echo "error: build succeeded but $APP_PATH does not exist" >&2
  exit 1
fi

# Copy into dist/ so it is inspectable after the script exits.
mkdir -p dist
rm -rf dist/MacPhone.app
cp -R "$APP_PATH" dist/MacPhone.app
echo "Built dist/MacPhone.app"

if [[ "${1:-}" == "build-only" ]]; then
  exit 0
fi

pkill -x MacPhone >/dev/null 2>&1 || true
open dist/MacPhone.app
