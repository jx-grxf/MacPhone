#!/usr/bin/env bash
# End-to-end check without MacPhone or a real device: a mock GATT source, the bridge
# publishing it on netsim, and a probe connecting from the emulator side.
# Needs only a running Android emulator and bridge/.venv (see run_bridge.sh).
set -euo pipefail
cd "$(dirname "$0")"

export MACPHONE_BRIDGE_PORT=8799
export MACPHONE_BRIDGE_HOST=127.0.0.1
export MACPHONE_BRIDGE_TOKEN=demo
logs="$(mktemp -d)"
pids=()

cleanup() { for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done; }
trap cleanup EXIT

echo "[1/3] mock GATT source (log: $logs/mock.log)"
.venv/bin/python -u mock_bridge_server.py >"$logs/mock.log" 2>&1 &
pids+=($!)
sleep 1
echo "[2/3] bridge on netsim (log: $logs/bridge.log)"
.venv/bin/python -u macphone_netsim_bridge.py >"$logs/bridge.log" 2>&1 &
pids+=($!)
sleep 3
echo "[3/3] probe connecting from the emulator side"
.venv/bin/python -u netsim_central_probe.py
