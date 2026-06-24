---
tags: [module, process, concurrency]
---

# CommandRunner

**File:** `Sources/MacPhone/Services/CommandRunner.swift`

## Purpose

`actor`. The single place external processes are launched. Used by every fleet service.

## `run(_:_:timeout:)`

- Runs the `Process` inside `Task.detached(.utility)` so the main actor never blocks.
- **Drains stdout and stderr concurrently** via `readabilityHandler` into a thread-safe `DataBox` — output larger than the OS pipe buffer (~64 KB, e.g. `simctl list --json`) would otherwise deadlock the child while we wait.
- Enforces a **wall-clock timeout** (default 20s): polls `process.isRunning`, terminates + throws `CommandRunnerError.timedOut` past the deadline.
- Reads any trailing buffered bytes after exit, returns `CommandResult(exitCode, stdout, stderr)`.

## `launchDetached(_:_:)`

Starts a long-lived process (the Android emulator) and returns immediately; output goes to `/dev/null`. The process is controlled afterwards via `adb`/console.

## `DataBox`

`private final class @unchecked Sendable`. `NSLock`-guarded `Data` accumulator, because `readabilityHandler` callbacks fire on an arbitrary queue. → [[State and Concurrency]]

## Interplay

- ← [[AndroidOrchestrator]], [[IOSSimulatorOrchestrator]], [[DeviceControlService]]

## Related notes

→ [[State and Concurrency]]
→ [[Fleet Orchestration]]
