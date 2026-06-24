---
tags: [module, ble, corebluetooth, mainactor]
---

# BLEBridgeService

**File:** `Sources/MacPhone/Services/BLEBridgeService.swift`

## Purpose

`@Observable @MainActor final class`, `NSObject`. CoreBluetooth **central** on the Mac's internal radio — no USB controller. Scans, connects, discovers GATT, reads/writes/notifies, and drives the live Bluetooth UI. Owns the [[BLEBridgeServer]] and feeds it the GATT mirror.

## Observable state

| Property | Type |
|---|---|
| `connectionState` | `BLEConnectionState` (idle/scanning/connecting/connected/disconnected) |
| `managerState` | `CBManagerState` |
| `discovered` | `[DiscoveredPeripheral]` (sorted by RSSI) |
| `services` | `[BLEService]` (the GATT model) |
| `log` | `[BLELogEntry]` (capped at 500) |
| `connectedPeripheralID` | `UUID?` |
| `server` | the owned [[BLEBridgeServer]] |

## Lifecycle

- `start()` creates `CBCentralManager(delegate:queue: nil)` — **nil queue → callbacks on the main queue**, matching `@MainActor`. Wires the server.
- `startBridgeServer(port:)` / `stopBridgeServer()` toggle the localhost server.

## GATT operations

`startScan` / `stopScan` / `connect` / `disconnect`, and `readValue` / `setNotify` / `write(hex:…)`. `cbCharacteristic(for:)` maps a model characteristic back to its `CBCharacteristic`.

## Server wiring

- `server.onClientConnected` → re-broadcast `state` + full `gatt` so a late-joining bridge catches up.
- `server.onCommand` → route `read`/`subscribe`/`write` [[Bridge Wire Protocol|commands]] to GATT ops via `findCharacteristic`.

## Rebuild vs. update

- `rebuildGATT(from:)` — rebuilds the whole `services` tree, **only on structural discovery**, and broadcasts the `gatt` payload. Stable model ids keep SwiftUI identities intact.
- `updateValue(...)` — updates one characteristic's value/notify flag in place (cheap), used on every notification; broadcasts a single `value` event.

## Delegates

`CBCentralManagerDelegate` + `CBPeripheralDelegate` methods are `nonisolated`; each hops back with `Task { @MainActor in … }`. Notifications (`didUpdateValueFor`) append a log line and broadcast `value` when the server is running.

## Interplay

- → [[BLEBridgeServer]] (owns; broadcasts events, receives commands)
- ← `BluetoothBridgeView` (UI)
- model: [[Bridge Wire Protocol]], `BLEModels.swift`

## Related notes

→ [[BLE Bridge Subsystem]]
→ [[Bridge Wire Protocol]]
→ [[GATT-layer Mirror not Link-layer]]
