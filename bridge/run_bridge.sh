#!/usr/bin/env bash
# Runs the netsim bridge by hand against a running MacPhone. MacPhone normally starts it
# itself ("Mirror to Emulator"); this is for working on the bridge.
#
# Needs: a running Android emulator, and a device (or the demo device) active in MacPhone.
set -euo pipefail
cd "$(dirname "$0")"

if [ ! -x .venv/bin/python ]; then
  python3 -m venv .venv
  .venv/bin/python -m pip install --quiet --upgrade pip
  .venv/bin/python -m pip install --quiet -r requirements.txt
fi

exec .venv/bin/python -u macphone_netsim_bridge.py
