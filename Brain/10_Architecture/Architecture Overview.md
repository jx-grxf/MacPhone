---
tags: [architecture, overview]
---

# Architecture Overview

MacPhone is a native macOS SwiftUI app built as a **SwiftPM executable target** (`MacPhone`, macOS 14+). No `.xcodeproj` — `Package.swift` is the source of truth. The app pairs with a small **Python `bridge/`** that runs the emulator side of the BLE bridge.

## Two subsystems

1. **Fleet orchestration** — many Android emulators + iOS simulators, first-party tooling only. → [[Fleet Orchestration]]
2. **No-dongle BLE bridge** — Mac as CoreBluetooth central, GATT mirrored to the emulator's netsim controller. → [[BLE Bridge Subsystem]]

## Module layout

```
Sources/MacPhone/
├── App/        ← @main App scene, AppDelegate, ⌘R command
├── Views/      ← NavigationSplitView shell, device lists, BLE bridge UI
├── Stores/     ← DeviceStore (@Observable fleet state)
├── Services/   ← AndroidOrchestrator, IOSSimulatorOrchestrator, DeviceControlService,
│                 CommandRunner, BLEBridgeService, BLEBridgeServer, DiscoveryResult
├── Models/     ← MobileDevice, BLEModels, DeviceSection
└── Support/    ← AndroidSDK, formatting helpers
bridge/         ← Python (Bumble): macphone_netsim_bridge.py, mock_bridge_server.py,
                  netsim_central_probe.py, run_*.sh
```

## UI shell

```
MacPhoneApp (WindowGroup "main")
└── ContentView  (NavigationSplitView)
    ├── SidebarView  → DeviceSection: Overview / Android / iOS / Bluetooth
    └── DetailView
        ├── OverviewView      (metrics + setup issues)
        ├── DeviceListView    (Android / iOS, boot/stop/wipe actions)
        └── BluetoothBridgeView (scan, GATT tree, server, activity log)
```

`MacPhoneApp` owns one `DeviceStore` and one `BLEBridgeService` as `@State`, refreshes the fleet on launch, and exposes a ⌘R "Refresh Devices" command. The selected section persists via `@SceneStorage`.

## The boundary that matters

The Swift app is the **central** (real radio + UI + localhost server). The Python `bridge/` is the **emulator-side peripheral**. They are fully decoupled by a newline-JSON TCP protocol on `127.0.0.1:8765`, so either side can be swapped or tested alone. → [[Bridge Wire Protocol]]

## Swift settings

- Swift toolchain via SwiftPM; macOS 14+ deployment target.
- CoreBluetooth + Network.framework; no third-party Swift packages.
- `@Observable` everywhere; the BLE types are `@MainActor`. → [[State and Concurrency]]

## Related notes

→ [[Fleet Orchestration]]
→ [[BLE Bridge Subsystem]]
→ [[State and Concurrency]]
→ [[Build and Run]]
