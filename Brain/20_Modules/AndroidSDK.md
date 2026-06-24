---
tags: [module, android, sdk]
---

# AndroidSDK

**File:** `Sources/MacPhone/Support/AndroidSDK.swift`

## Purpose

`struct`. Locates the Android SDK and resolves the binaries the fleet needs, so discovery and lifecycle control agree on the same `emulator`/`adb`.

## Location order

`locate()` returns the first existing path among:

1. `$ANDROID_HOME`
2. `$ANDROID_SDK_ROOT`
3. `~/Library/Android/sdk`

Returns `nil` if none exist → callers surface "Android SDK not found. Set ANDROID_HOME or install Android Studio."

## Resolved paths

| Property | Path |
|---|---|
| `emulatorPath` | `<root>/emulator/emulator` |
| `adbPath` | `<root>/platform-tools/adb` |
| `hasEmulator` / `hasADB` | `isExecutableFile` checks |

## Interplay

- ← [[AndroidOrchestrator]] (discovery), [[DeviceControlService]] (lifecycle)

## Related notes

→ [[Fleet Orchestration]]
