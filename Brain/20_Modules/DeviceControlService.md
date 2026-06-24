---
tags: [module, fleet, lifecycle]
---

# DeviceControlService

**File:** `Sources/MacPhone/Services/DeviceControlService.swift`

## Purpose

`struct`. Boots, stops, and wipes a `MobileDevice` through **first-party tools only**. Branches on `device.platform`.

## iOS (`xcrun simctl`)

| Action | Command | Notes |
|---|---|---|
| boot | `simctl boot <udid>` | "current state: Booted" treated as benign; then `open -a Simulator` to surface UI |
| stop | `simctl shutdown <udid>` | "current state: Shutdown" benign |
| wipe | `simctl erase <udid>` | device must be shut down first |

## Android (`emulator` / `adb`)

| Action | Command | Notes |
|---|---|---|
| boot | `emulator -avd <name>` **detached** | optional `-no-window -no-boot-anim` (headless), `-no-snapshot-load` (cold boot) |
| stop | `adb -s <serial> emu kill` | |
| wipe | `emulator -avd <name> -wipe-data -no-boot-anim` detached | kills the running AVD first; a running AVD can't be wiped in place |

Boot uses `CommandRunner.launchDetached` because the emulator process lives for the device's lifetime. `avdNameForWipe` falls back to the display name when the identifier is a running serial.

## Errors

`ControlError`: `androidSDKMissing`, `toolMissing`, `commandFailed`, `unsupported` — surfaced via `DeviceStore.lastActionError`.

## Interplay

- → [[AndroidSDK]], [[CommandRunner]]
- ← [[DeviceStore]] via `perform()`

## Related notes

→ [[Fleet Orchestration]]
