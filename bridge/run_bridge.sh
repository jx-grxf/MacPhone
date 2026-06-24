#!/usr/bin/env bash
# Runs the netsim bridge against the live MacPhone app (BLEBridgeServer on 127.0.0.1:8765).
#
# Prereqs:
#   1. Android emulator running (so netsim is up).
#   2. In MacPhone: Bluetooth tab → Scan → Connect to a BLE device → Start Server.
#
# Then: ./run_bridge.sh   (keeps running until Ctrl+C)
set -euo pipefail
cd "$(dirname "$0")"

if [ ! -d .venv ]; then
  echo "Creating venv + installing bumble…"
  python3 -m venv .venv
  .venv/bin/python -m pip install --quiet --upgrade pip
  .venv/bin/python -m pip install --quiet bumble
fi

exec .venv/bin/python -u macphone_netsim_bridge.py
