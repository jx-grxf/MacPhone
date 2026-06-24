#!/usr/bin/env bash
# Launch the emulated Xiaomi M365 scooter on the running emulator's netsim controller.
# Requires the Android emulator to be running (so netsim is up) and the bumble venv.
set -euo pipefail
cd "$(dirname "$0")"

if [ ! -x .venv/bin/python ]; then
  echo "Python venv missing. Run: python3 -m venv .venv && .venv/bin/pip install bumble" >&2
  exit 1
fi

exec .venv/bin/python -u m365_scooter.py
