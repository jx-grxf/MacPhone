#!/usr/bin/env bash
# Validate release metadata without building the app. CI runs this on every PR;
# the release workflow additionally supplies the expected tag/version/build.
set -euo pipefail

cd "$(dirname "$0")/.."

PROJECT_VERSION="$(awk -F'"' '/MARKETING_VERSION:/ { print $2; exit }' project.yml)"
PROJECT_BUILD="$(awk -F'"' '/CURRENT_PROJECT_VERSION:/ { print $2; exit }' project.yml)"
NOTES_VERSION="$(awk '/^## / { print $2; exit }' RELEASE_NOTES.md)"

fail() {
  echo "error: $*" >&2
  exit 1
}

[[ "$PROJECT_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-beta\.[0-9]+)?$ ]] \
  || fail "MARKETING_VERSION '$PROJECT_VERSION' is not a supported semantic version"
[[ "$PROJECT_BUILD" =~ ^[1-9][0-9]*$ ]] \
  || fail "CURRENT_PROJECT_VERSION '$PROJECT_BUILD' must be a positive integer"
[[ "$NOTES_VERSION" == "$PROJECT_VERSION" ]] \
  || fail "top release-notes version '$NOTES_VERSION' does not match project version '$PROJECT_VERSION'"

if [[ -n "${MACPHONE_VERSION:-}" && "$MACPHONE_VERSION" != "$PROJECT_VERSION" ]]; then
  fail "requested version '$MACPHONE_VERSION' does not match project version '$PROJECT_VERSION'"
fi
if [[ -n "${MACPHONE_BUILD:-}" && ! "$MACPHONE_BUILD" =~ ^[1-9][0-9]*$ ]]; then
  fail "release build '$MACPHONE_BUILD' must be a positive integer"
fi
if [[ -n "${MACPHONE_RELEASE_TAG:-}" && "$MACPHONE_RELEASE_TAG" != "v$PROJECT_VERSION" ]]; then
  fail "release tag '$MACPHONE_RELEASE_TAG' must equal 'v$PROJECT_VERSION'"
fi

case "${MACPHONE_UPDATE_CHANNEL:-}" in
  "") ;;
  stable)
    [[ "$PROJECT_VERSION" != *-* ]] || fail "stable releases cannot use a prerelease version"
    ;;
  beta)
    [[ "$PROJECT_VERSION" == *-beta.* ]] || fail "beta releases must use a -beta.N version"
    ;;
  *) fail "update channel must be stable or beta" ;;
esac

python3 - <<'PY'
import json
from pathlib import Path

path = Path("Config/Package.resolved")
if not path.is_file():
    raise SystemExit("error: Config/Package.resolved is missing")
data = json.loads(path.read_text())
pins = {pin["identity"]: pin["state"].get("revision") for pin in data.get("pins", [])}
if "sparkle" not in pins:
    raise SystemExit("error: package lock is missing the sparkle pin")
if not pins["sparkle"]:
    raise SystemExit("error: sparkle must be locked to a revision")
PY

echo "release metadata ok (version $PROJECT_VERSION, project build $PROJECT_BUILD)"
