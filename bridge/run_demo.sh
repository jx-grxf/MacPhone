#!/usr/bin/env bash
# Self-contained end-to-end proof — no real BLE device or MacPhone app needed.
# Starts a fake GATT source (mock_bridge_server), publishes it on the emulator's
# netsim as "MacPhone Bridge", then connects from the emulator side and reads +
# subscribes, printing the live data. Requires only a running Android emulator.
set -euo pipefail
cd "$(dirname "$0")"

export MACPHONE_BRIDGE_PORT=8799
export MACPHONE_BRIDGE_HOST=127.0.0.1

cleanup() { pkill -f mock_bridge_server.py 2>/dev/null || true; pkill -f macphone_netsim_bridge.py 2>/dev/null || true; }
trap cleanup EXIT
cleanup; sleep 1

echo "[1/3] starting mock GATT source…"
.venv/bin/python -u mock_bridge_server.py >/tmp/macphone_mock.log 2>&1 &
sleep 1
echo "[2/3] publishing on netsim as 'MacPhone Bridge'…"
.venv/bin/python -u macphone_netsim_bridge.py >/tmp/macphone_bridge.log 2>&1 &
sleep 3
echo "[3/3] connecting from the emulator side (central probe)…"
.venv/bin/python -u netsim_central_probe.py 2>&1 | grep -vE "Deprecation|fork_posix|RemoteLink|open_transport_or_link"
