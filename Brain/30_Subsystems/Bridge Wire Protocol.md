---
tags: [subsystem, ble, protocol, json]
---

# Bridge Wire Protocol

The contract between the Mac app and the emulator-side bridge. One JSON object per line, UTF-8, newline-delimited (`0x0A`), over TCP on **`127.0.0.1:8765`** (localhost only).

## Mac → client (events)

Emitted by `BLEBridgeServer.broadcast`, sourced from [[BLEBridgeService]].

```json
{"type":"state","value":"connected"}
{"type":"gatt","services":[{"uuid":"…","characteristics":[{"uuid":"…","properties":["read","notify"]}]}]}
{"type":"value","characteristic":"…","value":"<hex>"}
```

- `state` value is `connected` / `disconnected`.
- `gatt` is the full service tree, emitted on structural discovery and on late client join.
- `value` is one characteristic update (notification result or read result).

## client → Mac (commands)

Parsed by `BLEBridgeServer.parseCommand` into a `BridgeCommand`, executed against the real peripheral.

```json
{"cmd":"read","characteristic":"…"}
{"cmd":"subscribe","characteristic":"…","enabled":true}
{"cmd":"write","characteristic":"…","value":"<hex>","withResponse":true}
```

## Conventions

- **Property labels** in `gatt`: `read`, `write`, `writeNR`, `notify`, `indicate` (from `CBCharacteristicProperties.labels`).
- **Values** are lowercase hex strings (`Data.hexString` ↔ `Data(hexString:)`).
- **Defaults:** `subscribe.enabled` defaults `true`; `write.withResponse` defaults `true`.
- A command for an unknown characteristic is logged and dropped.

## Related notes

→ [[BLEBridgeServer]]
→ [[BLEBridgeService]]
→ [[netsim Bridge (Python)]]
