---
tags: [subsystem, ble, bridge, netsim]
---

# BLE Bridge Subsystem

Pass a **real BLE device** connected to the Mac through to an **Android emulator**, with **no external Bluetooth hardware**. The Mac's internal radio is the BLE central; the device's GATT is mirrored as a virtual peripheral on the emulator's netsim controller.

## Why it works without a dongle

macOS owns the internal controller's HCI; there is no supported way to hand that raw HCI link to the emulator's virtual controller (netsim/RootCanal). The only dongle-free option is to bridge **one level up — at the GATT/application layer**. This is sufficient for e-scooters (Xiaomi/Ninebot) because their security is **application-layer** (NinebotCrypto: SHA-1/AES/CRC over 20-byte chunks), not BLE link-layer pairing/bonding. → [[GATT-layer Mirror not Link-layer]]

## Data path

```
Real BLE device ──BLE──▶ BLEBridgeService (CoreBluetooth central, Mac internal radio)
                              │
                              ▼
                    BLEBridgeServer  (127.0.0.1:8765, newline JSON)
                              │
                              ▼
                 macphone_netsim_bridge.py (Bumble)
                              │  advertises "MacPhone Bridge"
                              ▼
                    android-netsim ──▶ Android app under test
```

One real device = one virtual peripheral (`MacPhone Bridge`) in the emulator. Reads/writes/notifications are relayed both ways.

## Flow details

- **Late-join replay.** A bridge that connects after the device is already connected still gets the current `state` + full `gatt` (via `BLEBridgeServer.onClientConnected`). → [[BLEBridgeService]]
- **Rebuild vs. update.** The full service tree is rebuilt only on structural discovery; notifications update one characteristic in place and emit a single `value` event.
- **Auto-subscribe.** The Python side subscribes every notify/indicate characteristic on the real device, so the stream flows without the app asking.

## Components

- [[BLEBridgeService]] — CoreBluetooth central.
- [[BLEBridgeServer]] — localhost TCP server / protocol endpoint.
- [[netsim Bridge (Python)]] — the emulator-side Bumble peripheral.
- [[Bridge Wire Protocol]] — the JSON on the wire.

## Pitfalls

- [[netsim TMPDIR Discovery]]
- [[Classic vs BLE Limitation]]
- [[GATT-layer Mirror not Link-layer]]

## Related notes

→ [[Architecture Overview]]
→ [[Fleet Orchestration]]
