---
tags: [build, run, spm, bridge]
---

# Build and Run

## Overview

MacPhone is a **SwiftPM executable** (`Package.swift`, target `MacPhone`, macOS 14+). There is **no `.xcodeproj`** and no third-party Swift packages — only CoreBluetooth + Network.framework.

## App

```sh
./script/build_and_run.sh            # build, assemble dist/MacPhone.app, launch
./script/build_and_run.sh --debug    # lldb on the binary
./script/build_and_run.sh --logs     # launch + stream os_log for the process
./script/build_and_run.sh --telemetry# launch + stream the bundle-id subsystem log
./script/build_and_run.sh --verify   # launch and assert the process is alive
```

The script generates the Xcode project with XcodeGen, builds it with
`xcodebuild`, and launches the native `.app`:

| Key | Value |
|---|---|
| `CFBundleIdentifier` | `dev.johannesgrof.MacPhone` |
| `LSMinimumSystemVersion` | `14.0` |
| `NSBluetoothAlwaysUsageDescription` | Bluetooth bridge usage string |
| `NSPrincipalClass` | `NSApplication` |

Use this path for local work so the build matches CI, Sparkle packaging, and the
asset-catalog configuration.

## BLE bridge (Python side)

```sh
cd bridge
python3 -m venv .venv && .venv/bin/python -m pip install bumble

./run_demo.sh      # Test A: self-contained netsim proof (no real device, no app)
./run_bridge.sh    # Test B: bridge a real device connected via the MacPhone app
```

- **Test A** uses `mock_bridge_server.py` + `netsim_central_probe.py` to prove the full GATT path through netsim. Expected tail: `PASS: received N notification(s)…`.
- **Test B**: start the emulator, in MacPhone → Bluetooth scan/connect/Start Server, then `./run_bridge.sh`, then connect from a BLE client in the emulator.

See `bridge/README.md` for the full runbook, and [[netsim TMPDIR Discovery]] if netsim isn't found.

## Related notes

→ [[Architecture Overview]]
→ [[BLE Bridge Subsystem]]
