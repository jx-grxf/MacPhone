---
tags: [module, android, discovery]
---

# AndroidOrchestrator

**File:** `Sources/MacPhone/Services/AndroidOrchestrator.swift`

## Purpose

`struct`. Discovers the Android side of the fleet. Returns a [[Fleet Orchestration|DiscoveryResult]] of devices + non-fatal issues.

## Flow

1. `AndroidSDK.locate()` → emulator/adb paths (or a warning issue if missing). → [[AndroidSDK]]
2. `emulator -list-avds` → AVD definitions (`parseAVDs`).
3. `adb devices -l` → running serials like `emulator-5554` (`parseADBDevices`, parses `model:` for a name).
4. `mergeDevices` → a running AVD shows up in both lists; resolve its AVD name via `adb -s <serial> emu avd name` and **fold it onto the matching definition** so it appears once, marked `Running (emulator-5554)`. Unmatched adb devices stay standalone.

## Notes

- All process spawning goes through [[CommandRunner]] (timeouts, pipe draining).
- Every failure is downgraded to a `DiscoveryIssue` (warning), never a throw — the iOS side still loads.

## Interplay

- → [[AndroidSDK]], [[CommandRunner]]
- ← [[DeviceStore]] calls `discover()`
- shares `emulator`/`adb` paths with [[DeviceControlService]]

## Related notes

→ [[Fleet Orchestration]]
