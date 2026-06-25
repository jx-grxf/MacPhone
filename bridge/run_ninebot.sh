#!/usr/bin/env bash
# Launch an emulated Ninebot scooter (encrypted transport) on the running emulator's netsim
# controller, so E-Tune can pair and exercise the full Ninebot flow without real hardware.
#
# Usage:
#   ./run_ninebot.sh [model]
# model = g2 | g3 | g30 | e22 | e25 | e45 | es1 | es2 | es4 | f65 | f2 | f2plus | f2pro | zt3pro
#         (default: g2)
#
# Requires the Android emulator to be running (netsim comes up with it).
set -euo pipefail
cd "$(dirname "$0")"

MODEL="${1:-g2}"

if [ ! -x .venv/bin/python ]; then
  echo "Creating Python venv (bumble + cryptography)…" >&2
  python3 -m venv .venv
  .venv/bin/pip install -q --upgrade pip
  .venv/bin/pip install -q bumble cryptography
fi

echo "Starting emulated Ninebot '$MODEL'. Connect in E-Tune (Devices → Scan)." >&2
exec env NB_MODEL="$MODEL" .venv/bin/python -u ninebot_scooter.py
