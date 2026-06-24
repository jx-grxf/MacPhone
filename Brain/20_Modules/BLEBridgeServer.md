---
tags: [module, ble, network, server, mainactor]
---

# BLEBridgeServer

**File:** `Sources/MacPhone/Services/BLEBridgeServer.swift`

## Purpose

`@Observable @MainActor final class`. Localhost TCP server (Network.framework) that exposes the live GATT mirror to the emulator side. Newline-delimited JSON on **`127.0.0.1:8765`** (bound localhost-only via `requiredLocalEndpoint`).

## State

| Property | Type |
|---|---|
| `isRunning` | `Bool` |
| `port` | `UInt16` (default 8765) |
| `clientCount` | `Int` |
| `lastError` | `String?` |

Callbacks set by the owner: `onCommand: (BridgeCommand) -> Void`, `onClientConnected: () -> Void` (for late-join replay).

## Lifecycle

- `start(port:)` builds an `NWListener` on a dedicated `DispatchQueue`; `stateUpdateHandler` hops to `@MainActor` for `isRunning`/`lastError`.
- `stop()` cancels all connections + the listener.

## I/O

- `broadcast(_:)` — JSON-encodes a `[String: Any]` event, appends `0x0A`, sends to every connection.
- `accept` / `receive` — buffer inbound bytes, split on newline, parse each line.
- `parseCommand` — `static`, `nonisolated`; turns a JSON line into a `BridgeCommand` (`read` / `subscribe` / `write`); unknown shapes return `nil`.

## BridgeCommand

```swift
enum BridgeCommand {
    case read(characteristic: String)
    case subscribe(characteristic: String, enabled: Bool)
    case write(characteristic: String, hex: String, withResponse: Bool)
}
```

## Interplay

- ← [[BLEBridgeService]] (owns it; sets callbacks; calls `broadcast`)
- → [[netsim Bridge (Python)]] is the typical client
- protocol: [[Bridge Wire Protocol]]

## Related notes

→ [[BLE Bridge Subsystem]]
→ [[Bridge Wire Protocol]]
→ [[State and Concurrency]]
