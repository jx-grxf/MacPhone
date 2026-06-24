---
tags: [architecture, concurrency, mainactor]
---

# State and Concurrency

## Observation

`DeviceStore`, `BLEBridgeService`, and `BLEBridgeServer` are all `@Observable`. SwiftUI binds to them directly — no `ObservableObject`/Combine.

## Actor isolation

- **`BLEBridgeService` / `BLEBridgeServer` are `@MainActor`.** CoreBluetooth's `CBCentralManager` is created with a **`nil` delegate queue**, so its callbacks arrive on the main queue, matching `@MainActor`. The `CBCentralManagerDelegate` / `CBPeripheralDelegate` methods are declared `nonisolated` and hop back with `Task { @MainActor in … }`.
- **`CommandRunner` is an `actor`.** The actual `Process` execution runs inside a `Task.detached(priority: .utility)`, so the main actor never blocks on a child process. → [[CommandRunner]]
- **`DataBox`** (inside `CommandRunner`) is `@unchecked Sendable` guarded by an `NSLock`, because `readabilityHandler` callbacks fire on an arbitrary queue.

## Fan-out / serialization

- **Discovery fans out:** Android + iOS via `async let` in `DeviceStore.refresh()`.
- **Control serializes per device:** a `busyDeviceIDs: Set<String>` gate prevents two simultaneous actions on the same device; the UI shows per-device busy state.

## Network server threading

`BLEBridgeServer` runs its `NWListener`/`NWConnection`s on a dedicated `DispatchQueue`. Connection accept/teardown and client count hop back to `@MainActor`. Inbound bytes are buffered and split on `0x0A` (newline) before each complete line is dispatched as a `BridgeCommand` on the main actor. → [[Bridge Wire Protocol]]

## Related notes

→ [[Architecture Overview]]
→ [[CommandRunner]]
→ [[BLEBridgeServer]]
