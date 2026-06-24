---
tags: [module, ios, discovery]
---

# IOSSimulatorOrchestrator

**File:** `Sources/MacPhone/Services/IOSSimulatorOrchestrator.swift`

## Purpose

`struct`. Discovers the iOS side of the fleet via Apple's `simctl`.

## Flow

1. `xcrun simctl list devices --json` (through [[CommandRunner]]).
2. `parseDevices` walks `root["devices"]` (keyed by runtime), flattens to `[MobileDevice]`.
3. Drops devices where `isAvailable == false`.
4. `readableRuntime` strips the `com.apple.CoreSimulator.SimRuntime.` prefix and replaces `-` with spaces.

Each device id is `ios-sim-<udid>`; `state` is the raw simctl state (`Booted`, `Shutdown`, …) which `MobileDevice.isRunning` keys off.

## Notes

- Missing Xcode command-line tools → a single warning `DiscoveryIssue`, not a throw.
- The large `--json` output is why [[CommandRunner]] drains pipes concurrently.

## Interplay

- → [[CommandRunner]]
- ← [[DeviceStore]] calls `discover()`

## Related notes

→ [[Fleet Orchestration]]
