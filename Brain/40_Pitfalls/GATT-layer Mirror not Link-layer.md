---
tags: [pitfall, ble, gatt, hci, critical]
---

# GATT-layer Mirror, not Link-layer

## Problem / hard truth

macOS owns the internal Bluetooth controller's **HCI**. There is **no supported way** to hand that raw HCI link to the Android emulator's virtual controller (netsim/RootCanal). So a true radio passthrough without an external dongle is impossible.

The bridge sidesteps this by mirroring **one level up — at the GATT/application layer**: it re-publishes services/characteristics and relays read/write/notify bytes. It does **not** carry a BLE **link-layer bond** (pairing/encryption) across the bridge.

## When this is fine

E-scooters (Xiaomi/Ninebot) put their security in the **application layer** (NinebotCrypto: SHA-1/AES/CRC over 20-byte chunks), not in BLE link-layer pairing. A GATT byte mirror is therefore sufficient — no bond crosses the bridge.

## When this is NOT enough

Any app that requires genuine **link-layer bonding/encryption** would still need a **real radio on the emulator side** (e.g. an external USB Bluetooth controller via a Bumble HCI bridge). The GATT mirror cannot fake a bond.

## Rule

Treat the bridge as an application-layer GATT relay. Before targeting a new device, confirm its security is app-layer, not link-layer. If it bonds/encrypts at the link layer, this dongle-free path will not work.

See [[BLE Bridge Subsystem]], [[Classic vs BLE Limitation]], [[BLEBridgeService]].
