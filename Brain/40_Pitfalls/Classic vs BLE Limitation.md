---
tags: [pitfall, ble, bluetooth-classic, corebluetooth]
---

# Classic vs BLE Limitation

## Problem

CoreBluetooth on macOS is **BLE-only**. Bluetooth **Classic** (BR/EDR) devices are invisible to the Mac side of the bridge and **cannot be bridged**: audio speakers (JBL), car stereos, classic headsets — none of them show up in [[BLEBridgeService]]'s scan, because the Mac never sees them as BLE peripherals.

A second, related trap: on the Android side, ***Settings → Pair new device*** is the Classic bonding flow. Pointing it at the BLE GATT peripheral (`MacPhone Bridge`) makes it **hang**.

## Good vs. bad targets

- **Good (BLE GATT):** e-scooters (Xiaomi/Ninebot), fitness bands, smart locks, BLE beacons, a phone running a BLE-peripheral app.
- **Bad:** anything Bluetooth Classic; also Apple devices (AirPods, Apple Watch) advertise but drop/refuse arbitrary GATT connections quickly.

## Rule

Only target BLE GATT devices. On Android, connect with a **BLE client** (nRF Connect) or `netsim_central_probe.py`, **never** the Settings pairing screen.

See [[BLE Bridge Subsystem]], [[GATT-layer Mirror not Link-layer]].
