---
tags: [glossary, reference]
---

# Glossary

| Term | Definition |
|---|---|
| **DeviceStore** | `@Observable final class`. The fleet state owner: `devices`, `issues`, `busyDeviceIDs`, `bootHeadless`. Runs Android + iOS discovery concurrently and drives boot/coldBoot/stop/wipe. → [[DeviceStore]] |
| **MobileDevice** | A fleet member: `id`, `name`, `platform` (.android/.ios), `runtime`, `state`, `identifier`. Derives `isRunning` / `canBoot`. → [[Fleet Orchestration]] |
| **AndroidOrchestrator** | `struct`. Discovers Android via `emulator -list-avds` + `adb devices -l`, then merges a running emulator onto its AVD via `adb … emu avd name`. → [[AndroidOrchestrator]] |
| **IOSSimulatorOrchestrator** | `struct`. Discovers iOS via `xcrun simctl list devices --json`. → [[IOSSimulatorOrchestrator]] |
| **DeviceControlService** | `struct`. Boots/stops/wipes a device with first-party tools only (`simctl`, `emulator`, `adb`). → [[DeviceControlService]] |
| **CommandRunner** | `actor`. Runs external processes, draining stdout/stderr concurrently with a wall-clock timeout. `launchDetached` for long-lived emulators. → [[CommandRunner]] |
| **AndroidSDK** | `struct`. Locates the SDK (`ANDROID_HOME` / `ANDROID_SDK_ROOT` / `~/Library/Android/sdk`) and resolves `emulator`/`adb`. → [[AndroidSDK]] |
| **BLEBridgeService** | `@Observable @MainActor`. CoreBluetooth **central** on the Mac's internal radio. Scan/connect/discover/read/write/notify; owns the server; rebuilds the GATT model and broadcasts events. → [[BLEBridgeService]] |
| **BLEBridgeServer** | `@Observable @MainActor`. Localhost TCP server (Network.framework) on `127.0.0.1:8765`, newline-delimited JSON. Broadcasts events, parses commands. → [[BLEBridgeServer]] |
| **BridgeCommand** | `enum { read, subscribe, write }`. Parsed from inbound JSON by `BLEBridgeServer`, executed against the real peripheral by `BLEBridgeService`. → [[Bridge Wire Protocol]] |
| **netsim Bridge (Python)** | `macphone_netsim_bridge.py`. Reads the GATT mirror over TCP and re-publishes it as a Bumble virtual peripheral (`MacPhone Bridge`) on `android-netsim`. → [[netsim Bridge (Python)]] |
| **netsim** | Android Emulator's virtual Bluetooth controller (successor to the obsolete `android-emulator` transport). Bumble connects via `android-netsim`. → [[BLE Bridge Subsystem]] |
| **netsim.ini** | File the emulator writes with `grpc.port=…`, located in the emulator's own (often per-app launchd) TMPDIR. → [[netsim TMPDIR Discovery]] |
| **GATT mirror** | Re-publishing a real device's services/characteristics + live values at the application layer, without crossing a link-layer bond. The core trick of the bridge. → [[GATT-layer Mirror not Link-layer]] |
| **DiscoveryResult / DiscoveryIssue** | Value pair of discovered `[MobileDevice]` and non-fatal `[DiscoveryIssue]` (missing tools, etc.). → [[Fleet Orchestration]] |
| **DeviceSection** | Sidebar enum: `.overview`, `.android`, `.ios`, `.bluetooth`. → [[Architecture Overview]] |
| **Bumble** | Google's Python Bluetooth stack used on the emulator side to present the virtual peripheral. → [[netsim Bridge (Python)]] |
