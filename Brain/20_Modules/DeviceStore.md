---
tags: [module, store, fleet, model]
---

# DeviceStore

**File:** `Sources/MacPhone/Stores/DeviceStore.swift`

## Purpose

`@Observable final class`. The single owner of fleet state. Composes the three fleet services and drives discovery + lifecycle for the UI.

## State

| Property | Type | Description |
|---|---|---|
| `devices` | `[MobileDevice]` | All discovered Android + iOS devices, sorted |
| `issues` | `[DiscoveryIssue]` | Non-fatal setup problems (missing tools, etc.) |
| `isRefreshing` | `Bool` | Discovery in flight |
| `busyDeviceIDs` | `Set<String>` | Devices mid boot/stop action |
| `lastActionError` | `String?` | Surfaced control-action error |
| `bootHeadless` | `Bool` | Boot new Android emulators with `-no-window` |

Computed: `androidDevices`, `iosDevices` filter by platform.

## Key methods

| Method | Description |
|---|---|
| `refresh()` | `@MainActor`. Runs `AndroidOrchestrator.discover()` and `IOSSimulatorOrchestrator.discover()` in parallel (`async let`), merges + sorts. Guarded against re-entry. |
| `boot` / `coldBoot` / `stop` / `wipe` | `@MainActor`. Each wraps `perform()`. |
| `perform(_:_:)` | Marks the device busy, runs the action via [[DeviceControlService]], then sleeps ~2s and re-runs `refresh()` (state changes are async). Serialized via `busyDeviceIDs`. |
| `isBusy(_:)` | Membership check for per-row UI. |

## Interplay

- → [[AndroidOrchestrator]], [[IOSSimulatorOrchestrator]] (discovery)
- → [[DeviceControlService]] (boot/stop/wipe)
- ← `ContentView` / `DeviceListView` bind to it
- uses [[CommandRunner]] indirectly through the services

## Related notes

→ [[Fleet Orchestration]]
→ [[State and Concurrency]]
