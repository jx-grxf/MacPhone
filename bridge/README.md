# MacPhone → Android Emulator BLE Bridge

Passes a **real BLE device** connected to the Mac through to an Android emulator,
with **no external Bluetooth hardware**. The Mac's internal radio acts as the BLE
central; the device's GATT is mirrored as a virtual peripheral on the emulator's
netsim controller.

```
Real BLE device ──BLE──▶ MacPhone.app (CoreBluetooth central, Mac internal radio)
                              │  127.0.0.1:8765  (newline JSON, BLEBridgeServer)
                              ▼
                     macphone_netsim_bridge.py
                              │  Bumble peripheral
                              ▼
                        android-netsim ──▶ Android app under test
```

One real device = one virtual peripheral (`MacPhone Bridge`) in the emulator. The
emulator sees and talks to that mirror; reads/writes/notifications are relayed to and
from the real device on the Mac.

## Scope & limits (read this)

- **BLE only.** CoreBluetooth on macOS cannot access **Bluetooth Classic** (BR/EDR).
  Classic audio devices (speakers like a JBL, car stereos, classic headsets) are
  invisible to the Mac side and **cannot** be bridged. Good targets: e-scooters
  (Xiaomi/Ninebot), fitness bands, smart locks, BLE beacons, or a phone running a
  BLE-peripheral app.
- **Connect from a BLE app, not Android Settings.** The Android *Settings → Pair new
  device* screen is for Classic bonding and will hang on a BLE GATT peripheral. Use a
  BLE client (e.g. nRF Connect for Android), or the included `netsim_central_probe.py`.
- Apple devices (AirPods, Apple Watch) advertise but drop/refuse arbitrary GATT
  connections quickly — poor test targets.

## Setup

```bash
cd bridge
python3 -m venv .venv
.venv/bin/python -m pip install bumble
```

## Test A — self-contained proof (no real device, no app needed)

Requires only a running Android emulator. Starts a fake GATT (battery + a Xiaomi-style
service), publishes it on netsim, then connects from the emulator side and reads +
subscribes:

```bash
./run_demo.sh
```

Expected tail:

```
PASS: received N notification(s). End-to-end GATT path through netsim works.
```

## Test B — real device through the MacPhone app

1. Start the Android emulator (so netsim is up).
2. In MacPhone → **Bluetooth**: **Scan** → **Connect** to your BLE device → wait for the
   GATT tree → **Start Server**.
3. Run the bridge:
   ```bash
   ./run_bridge.sh
   ```
   It connects to `127.0.0.1:8765`, reads the GATT, and advertises `MacPhone Bridge`
   on netsim.
4. In the emulator, open a **BLE client app** (nRF Connect), scan, connect to
   `MacPhone Bridge`, and read/write/subscribe. Traffic is relayed to the real device.

## Files

- `macphone_netsim_bridge.py` — the bridge (BLEBridgeServer JSON ↔ Bumble peripheral on netsim).
- `mock_bridge_server.py` — fake GATT source standing in for the MacPhone app.
- `netsim_central_probe.py` — automated BLE central on netsim (acts like the Android app).
- `run_bridge.sh` / `run_demo.sh` — convenience launchers.

## netsim discovery

The bridge finds netsim's gRPC port from `netsim.ini`, searching `$TMPDIR`,
`~/Library/Caches/TemporaryItems`, per-app launchd temp dirs, and `/tmp`. Override with
`MACPHONE_NETSIM_TRANSPORT=android-netsim:127.0.0.1:<port>` if needed.
