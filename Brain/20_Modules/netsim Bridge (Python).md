---
tags: [module, python, bumble, netsim, bridge]
---

# netsim Bridge (Python)

**File:** `bridge/macphone_netsim_bridge.py`

## Purpose

The **emulator side** of the BLE bridge. Reads the GATT mirror MacPhone publishes over its localhost [[BLEBridgeServer]] and re-publishes it as a **Bumble virtual peripheral** (`MacPhone Bridge`) on `android-netsim`, so the Android app under test sees the same services/characteristics as the real device — no dongle.

## Flow

1. `BridgeClient.connect()` → TCP to `127.0.0.1:8765`, reads newline JSON.
2. Awaits the `gatt` event, `build_services()` → Bumble `Service`/`Characteristic` tree; `read`/`write` handlers forward to the Mac as [[Bridge Wire Protocol|commands]].
3. Opens the netsim transport (`resolve_netsim_transport`), creates `Device.with_hci`, adds services, powers on.
4. **Auto-subscribes** every notify/indicate characteristic on the real device; routes incoming `value` events to `device.notify_subscribers`.
5. Advertises `MacPhone Bridge` (`UNDIRECTED_CONNECTABLE_SCANNABLE`, auto-restart), runs forever.

## netsim transport resolution

`resolve_netsim_transport()` honours `MACPHONE_NETSIM_TRANSPORT` if set; otherwise reads `grpc.port=` from `netsim.ini`, searching `$TMPDIR`, `~/Library/Caches/TemporaryItems`, `/var/folders/*/*/T`, `/tmp` — because the emulator's TMPDIR differs by launch context. → [[netsim TMPDIR Discovery]]

## Companions

- `mock_bridge_server.py` — fake GATT source standing in for the Mac app (Test A).
- `netsim_central_probe.py` — automated BLE central on netsim acting like the Android app.
- `run_demo.sh` (Test A, self-contained) / `run_bridge.sh` (Test B, real device).

## Interplay

- ← [[BLEBridgeServer]] (the JSON feed)
- → `android-netsim` → Android app

## Related notes

→ [[BLE Bridge Subsystem]]
→ [[Bridge Wire Protocol]]
→ [[netsim TMPDIR Discovery]]
