---
tags: [architecture, fleet, android, ios]
---

# Fleet Orchestration

The core product: discover, boot, stop, wipe, and inspect **many** Android emulators and iOS simulators at once, using only first-party tooling. Scale is bounded by RAM/CPU, not an API limit.

## Discovery (read path)

```
DeviceStore.refresh()
   ├─ async let  AndroidOrchestrator.discover()
   │     ├─ AndroidSDK.locate()  → emulator/adb paths
   │     ├─ emulator -list-avds          → AVD definitions
   │     ├─ adb devices -l               → running serials (emulator-5554, …)
   │     └─ merge: adb -s <serial> emu avd name → fold running AVD onto its definition
   └─ async let  IOSSimulatorOrchestrator.discover()
         └─ xcrun simctl list devices --json → flatten by runtime, drop unavailable
   →  devices: [MobileDevice]  +  issues: [DiscoveryIssue]
```

Discovery runs Android and iOS in parallel (`async let` in [[DeviceStore]]). Missing tools become non-fatal `DiscoveryIssue`s — the app still shows the other platform.

## Lifecycle (control path)

```
DeviceStore.boot / coldBoot / stop / wipe(device)
   └─ perform(): mark busy → DeviceControlService.<action> → sleep ~2s → refresh()
```

`DeviceControlService` branches on platform:

- **iOS:** `simctl boot|shutdown|erase` (already-in-state errors are benign); `open -a Simulator` on boot.
- **Android:** boot is a detached `emulator -avd <name>` (long-lived process) with optional `-no-window`/`-no-boot-anim` (headless) and `-no-snapshot-load` (cold); stop is `adb … emu kill`; wipe relaunches cold with `-wipe-data`.

State changes are async on the emulator/simulator side, so the store waits and re-discovers rather than mutating optimistically.

## Why first-party only

`Virtualization.framework` virtualizes only macOS/Linux guests, not Android — so the official Google Android Emulator (QEMU + Hypervisor.framework, arm64 images) is the native path. No BlueStacks/Genymotion. iOS is Apple-only via `simctl`. See [`docs/TECHNICAL_PLAN.md`].

## Modules

- [[DeviceStore]] · [[AndroidOrchestrator]] · [[IOSSimulatorOrchestrator]] · [[DeviceControlService]] · [[CommandRunner]] · [[AndroidSDK]]

## Related notes

→ [[Architecture Overview]]
→ [[BLE Bridge Subsystem]]
