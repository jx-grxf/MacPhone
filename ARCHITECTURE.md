# Architecture

MacPhone is a SwiftUI app (macOS 14+, Swift 6 with strict concurrency) generated with XcodeGen from `project.yml`, plus one Python script that runs in its own virtual environment.

## Layout

```
Sources/MacPhone/
  App/          MacPhoneApp, AppDelegate (owns the long-lived services)
  Models/       MobileDevice, DeviceFamily, DeviceState, BLE models, AppSection
  Services/     everything that talks to tools, radios or sockets
  Stores/       DeviceStore, SetupStore (@Observable, @MainActor)
  Views/        Bridge/, Devices/, Setup/, Shared/
  Support/      AndroidSDK, AndroidAVDPerformance, Design tokens
  Updates/      UpdateService (Sparkle)
bridge/         macphone_netsim_bridge.py and its test helpers
Tests/          Swift Testing: parsers, bridge protocol, CommandRunner
```

## Running tools

Every external command goes through `CommandRunner`. It drains stdout and stderr on their own threads from the moment the child starts, so output beyond the 64 KB pipe buffer cannot stall it, and a timeout sends SIGTERM, then SIGKILL three seconds later. `launchDetached` starts the emulator with its output in `~/Library/Logs/MacPhone/emulator-<avd>.log` and reports an exit within the first four seconds, which is how a locked AVD or missing image shows up.

`SimulatorService` wraps `xcrun simctl`. `AndroidService` wraps `emulator` and `adb`; it merges each running `emulator-NNNN` back onto its AVD with `adb emu avd name`. `AndroidProvisioner` and `SetupService` install things with `sdkmanager`, `avdmanager`, Homebrew, `xcodebuild -downloadPlatform` and pip.

`DeviceStore` queues a refresh that is requested while one is running, and polls every three seconds while any device is starting or stopping.

## Bluetooth bridge

```
BLE device ── CoreBluetooth ──> BLEBridgeService ──> BLEBridgeServer (127.0.0.1:8765)
                                                              │ JSON lines, token
                                                              v
                                           macphone_netsim_bridge.py (Bumble)
                                                              │ gRPC
                                                              v
                                                  netsim ──> app in the emulator
```

- `BLEBridgeService` is the CoreBluetooth central. Its state is one enum (`idle`, `scanning`, `connecting`, `connected`, `reconnecting`, `demo`) plus the one target peripheral; delegate callbacks for any other peripheral are ignored, so Stop always wins over a connect or reconnect in flight.
- When an emulator client disconnects, the bridge asks for `resetSession`: MacPhone drops and re-opens the link to the real device so the device's own session state starts clean. After rediscovery it re-applies every subscription the emulator side had made.
- Writes without response are queued while `canSendWriteWithoutResponse` is false instead of being dropped.
- `BLEBridgeServer` accepts at most two clients and requires a per-launch token as the first line; HTTP or any other first line closes the socket. That keeps web pages, which can POST to localhost, away from the real device. UUIDs and hex are validated before they reach `CBUUID`, which raises on bad input.
- `NetsimBridgeProcess` supervises the Python script and restarts it on exit code 75 (different GATT layout after a device switch).

The bridge mirrors GATT, not the link layer. macOS does not let apps hand the internal controller's HCI to another stack, so devices that need Bluetooth pairing or link-layer encryption cannot be bridged this way. Bluetooth Classic is not available to apps on macOS at all.

## Updates and releases

Sparkle 2.10 with an EdDSA-signed appcast. Stable clients read `releases/latest/download/appcast.xml`, beta clients the moving `beta` release. The release workflow, toolchain gates and verification scripts are described in `AGENTS.md` and `script/`.
