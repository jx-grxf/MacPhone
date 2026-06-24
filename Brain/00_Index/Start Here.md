---
tags: [index, navigation]
---

# MacPhone – Project Entry Point

MacPhone is a native macOS SwiftUI app (Swift Package executable target `MacPhone`, macOS 14+) that does two things, both with first-party tooling only:

1. **Multi-phone fleet orchestration** — discover/boot/stop/wipe many Android emulators (official Google emulator + Hypervisor.framework, arm64 images) and iOS simulators (`xcrun simctl`) at once.
2. **A no-dongle BLE bridge** — the Mac is a CoreBluetooth central on its internal radio, mirrors a real BLE device's GATT over a localhost TCP server, and a Python Bumble script re-publishes it as a virtual peripheral on the Android emulator's netsim controller. The data path is proven end-to-end.

It is **not** an iPhone emulator. Product positioning and research baseline live in [`docs/TECHNICAL_PLAN.md`]; the current architecture lives in [`ARCHITECTURE.md`]. For decisions and hard truths, see [[Architecture Overview]].

---

## Main areas

| Area | Entry point |
|---|---|
| Architecture + module map | [[Architecture Overview]] |
| Fleet discovery + lifecycle | [[Fleet Orchestration]] |
| The no-dongle BLE bridge | [[BLE Bridge Subsystem]] |
| Bridge wire protocol (JSON) | [[Bridge Wire Protocol]] |
| State / concurrency model | [[State and Concurrency]] |
| Build & run | [[Build and Run]] |
| Glossary | [[Glossary]] |

---

## Modules

| Module | Note |
|---|---|
| Fleet state store | [[DeviceStore]] |
| Android discovery | [[AndroidOrchestrator]] |
| iOS discovery | [[IOSSimulatorOrchestrator]] |
| Boot/stop/wipe | [[DeviceControlService]] |
| Process runner | [[CommandRunner]] |
| SDK locator | [[AndroidSDK]] |
| BLE central | [[BLEBridgeService]] |
| Localhost bridge server | [[BLEBridgeServer]] |
| Python emulator side | [[netsim Bridge (Python)]] |

---

## Critical pitfalls

- [[netsim TMPDIR Discovery]] — netsim.ini lands in a per-app launchd TMPDIR.
- [[Classic vs BLE Limitation]] — CoreBluetooth can't see Bluetooth Classic.
- [[GATT-layer Mirror not Link-layer]] — bonded/encrypted link-layer apps still need a real radio.

---

## If you want to change X…

| Goal | Read first |
|---|---|
| How devices are discovered | [[Fleet Orchestration]] + [[AndroidOrchestrator]] / [[IOSSimulatorOrchestrator]] |
| How a device boots/stops/wipes | [[DeviceControlService]] |
| Run an external process safely | [[CommandRunner]] |
| The BLE scan/connect/GATT path | [[BLEBridgeService]] |
| The localhost server / protocol | [[BLEBridgeServer]] + [[Bridge Wire Protocol]] |
| The emulator-side mirror | [[netsim Bridge (Python)]] + [[netsim TMPDIR Discovery]] |
| What the bridge can/can't bridge | [[Classic vs BLE Limitation]] + [[GATT-layer Mirror not Link-layer]] |
| Build / run the app | [[Build and Run]] |

---

## Glossary

→ [[Glossary]]
