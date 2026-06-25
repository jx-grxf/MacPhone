# MacPhone Architecture

This document describes how MacPhone is put together: the modules, the two subsystems (multi-phone fleet orchestration and the no-dongle BLE bridge), the data/control flow, the bridge wire protocol, and the hard technical truths every layer lives with.

For the product positioning, MVP scoping, and the research baseline that shaped these decisions, see [`docs/TECHNICAL_PLAN.md`](docs/TECHNICAL_PLAN.md).

---

## What MacPhone is

MacPhone is a **native macOS SwiftUI app** (Swift Package executable target `MacPhone`, macOS 14+) that does two things:

1. **Multi-phone fleet orchestration** — discover, boot, stop, wipe, and inspect **many** Android emulators and iOS simulators at once, using only first-party tooling: Google's official Android Emulator (QEMU + Hypervisor.framework, `arm64` images) via `emulator`/`adb`, and Apple's iOS Simulator via `xcrun simctl`. No third-party emulators (BlueStacks, Genymotion). Scale is bounded by RAM/CPU, not an API limit.
2. **A no-external-hardware BLE bridge** — the Mac acts as a CoreBluetooth **central** on its internal radio, connects to a real BLE device (e.g. a Xiaomi/Ninebot e-scooter), and re-publishes that device's GATT over a localhost TCP server. A Python Bumble script consumes the feed and mirrors the device as a **virtual peripheral** on the Android emulator's `netsim` controller, so an Android app under test talks "Bluetooth" to the real device with **no USB dongle**. The data path is proven end-to-end.

MacPhone is **not** an iPhone emulator and does not pretend to replace Apple's tools — it wraps and automates them.

---

## Module layout

```
MacPhone/
├── Package.swift                    ← SPM executable target "MacPhone" (macOS 14+)
├── ARCHITECTURE.md                  ← this file
├── docs/TECHNICAL_PLAN.md           ← product positioning, research, MVP scope
├── script/build_and_run.sh          ← build + bundle .app + launch
├── Sources/MacPhone/
│   ├── App/         ← @main App scene, NSApplicationDelegate, ⌘R menu
│   ├── Views/       ← SwiftUI: NavigationSplitView shell, device lists, BLE bridge UI
│   ├── Stores/      ← DeviceStore (@Observable fleet state)
│   ├── Services/    ← orchestrators, command runner, device control, BLE bridge
│   ├── Models/      ← MobileDevice, BLE GATT models, sections
│   └── Support/     ← AndroidSDK locator, formatting helpers
└── bridge/          ← Python (Bumble): the emulator side of the BLE bridge
    ├── macphone_netsim_bridge.py    ← BLEBridgeServer JSON ↔ Bumble peripheral on netsim
    ├── mock_bridge_server.py        ← fake GATT source standing in for the Mac app
    ├── netsim_central_probe.py      ← automated BLE central on netsim (acts like the app)
    └── run_bridge.sh / run_demo.sh  ← launchers
```

**The boundary that matters:** the Swift app is the **central** (the real radio + UI + the localhost server). The Python `bridge/` is the **emulator-side peripheral**. They are decoupled by a newline-delimited JSON TCP protocol on `127.0.0.1:8765` — either side can be swapped or tested in isolation (`mock_bridge_server.py` fakes the Mac; `netsim_central_probe.py` fakes the app).

---

## High-level diagram

```
                      ┌──────────────────────────── MacPhone.app (SwiftUI, macOS 14+) ────────────────────────────┐
                      │                                                                                            │
  ┌───── FLEET ───────┤   ContentView (NavigationSplitView)                                                        │
  │                   │      ├─ SidebarView  →  DeviceSection: Overview / Android / iOS / Bluetooth                │
  │                   │      └─ DetailView                                                                         │
  │                   │                                                                                            │
  │   DeviceStore  (@Observable)                                                                                   │
  │      ├─ AndroidOrchestrator ──┐                                                                                │
  │      ├─ IOSSimulatorOrchestrator ─┐   discover()                                                               │
  │      └─ DeviceControlService ──┐  │   boot/stop/wipe()                                                         │
  │                  └─────────────┴──┴──▶ CommandRunner (actor) ──▶ external processes                            │
  │                                            │                                                                   │
  │              ┌─────────────────────────────┼──────────────────────────────┐                                  │
  │              ▼                              ▼                              ▼                                   │
  │     emulator -list-avds            xcrun simctl …               adb -s … emu …                                │
  │     emulator -avd … (detached)     (Apple iOS Simulator)        (Android Emulator console)                    │
  │                                                                                                                │
  └─── BLE BRIDGE ────────────────────────────────────────────────────────────────────────────────────────────┐ │
      BluetoothBridgeView  →  BLEBridgeService (CoreBluetooth central, internal radio)                          │ │
                                   │  scan / connect / discover / read / write / notify                          │ │
                                   ▼                                                                              │ │
                              BLEBridgeServer (Network.framework, 127.0.0.1:8765, newline JSON)  ◀──────────┐    │ │
                      └────────────────────────────────────────────────────────────────────────────────────┼────┘ │
                                                                                                            │      │
   Real BLE device  ──BLE──▶  (Mac internal radio)                                                          │      │
                                                                                                            │      │
                              macphone_netsim_bridge.py (Bumble)  ◀── newline JSON over TCP ────────────────┘      │
                                   │  presents a virtual peripheral "MacPhone Bridge"                              │
                                   ▼                                                                               │
                              android-netsim  ──▶  Android app under test                                         │
                      └──────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## Module map

### Swift app (`Sources/MacPhone/`)

| File | Responsibility | Key types |
|---|---|---|
| `App/MacPhoneApp.swift` | `@main` App scene. Owns one `DeviceStore` and one `BLEBridgeService` as `@State`; refreshes on launch; adds a ⌘R "Refresh Devices" command. Sets `.regular` activation policy. | `MacPhoneApp`, `AppDelegate` |
| `Views/ContentView.swift` | The `NavigationSplitView` shell. Sidebar + detail, toolbar refresh button. Selected section persisted via `@SceneStorage`. | `ContentView` |
| `Views/SidebarView.swift` | Section list (Overview / Android / iOS / Bluetooth) + live Android/iOS/Issues status counts. | `SidebarView` |
| `Views/DetailView.swift` | Routes the selected `DeviceSection` to Overview metrics, a `DeviceListView`, or the BLE bridge view. | `DetailView`, `DeviceListView`, `OverviewView` |
| `Views/BluetoothBridgeView.swift` | The BLE bridge UI: scan list, connected GATT tree, Start/Stop server, activity log. Calls `ble.start()` on appear. | `BluetoothBridgeView`, `ActivityLogView` |
| `Stores/DeviceStore.swift` | `@Observable` fleet state. Runs Android + iOS discovery concurrently (`async let`), holds `devices`/`issues`, tracks per-device busy ids, and drives boot/coldBoot/stop/wipe with optimistic refresh. | `DeviceStore` |
| `Services/AndroidOrchestrator.swift` | Discovers Android: `emulator -list-avds` (definitions) + `adb devices -l` (running), then merges a running emulator back onto its AVD via `adb … emu avd name`. | `AndroidOrchestrator` |
| `Services/IOSSimulatorOrchestrator.swift` | Discovers iOS via `xcrun simctl list devices --json`, flattens runtimes, drops unavailable devices. | `IOSSimulatorOrchestrator` |
| `Services/DeviceControlService.swift` | Boots/stops/wipes a `MobileDevice` through first-party tools only — `simctl boot/shutdown/erase` for iOS; `emulator -avd … [-no-window] [-no-snapshot-load]` (detached) and `adb emu kill` for Android. | `DeviceControlService`, `ControlError` |
| `Services/CommandRunner.swift` | `actor` process runner. Drains stdout/stderr concurrently (so large `--json` output can't deadlock the pipe), enforces a wall-clock timeout. `launchDetached` for long-lived emulators. | `CommandRunner`, `CommandResult`, `DataBox` |
| `Services/BLEBridgeService.swift` | CoreBluetooth **central** on the Mac's internal radio. Scan/connect/discover/read/write/notify. Owns the `BLEBridgeServer`, rebuilds the GATT model, broadcasts state/gatt/value events, and routes inbound commands to GATT ops. | `BLEBridgeService` (+ `CBCentralManagerDelegate`, `CBPeripheralDelegate`) |
| `Services/BLEBridgeServer.swift` | Localhost TCP server (Network.framework) bound to `127.0.0.1:8765`. Newline-delimited JSON: broadcasts events to clients, parses inbound commands. | `BLEBridgeServer`, `BridgeCommand` |
| `Services/DiscoveryResult.swift` | Value type pairing discovered `[MobileDevice]` with `[DiscoveryIssue]`. | `DiscoveryResult` |
| `Models/MobileDevice.swift` | A fleet member (id, name, platform, runtime, state, identifier) with `isRunning`/`canBoot` derivation. | `MobileDevice`, `MobilePlatform`, `DiscoveryIssue`, `DiscoverySeverity` |
| `Models/BLEModels.swift` | GATT model for the UI/protocol: discovered peripheral, service, characteristic (with stable ids), connection state, log entry; `Data`↔hex and `CBCharacteristicProperties.labels`. | `DiscoveredPeripheral`, `BLEService`, `BLECharacteristic`, `BLEConnectionState`, `BLELogEntry` |
| `Models/DeviceSection.swift` | Sidebar sections enum. | `DeviceSection` |
| `Support/AndroidSDK.swift` | Locates the Android SDK (`ANDROID_HOME` / `ANDROID_SDK_ROOT` / `~/Library/Android/sdk`) and resolves the `emulator`/`adb` binaries. Shared by discovery and control. | `AndroidSDK` |
| `Support/*` | `DiscoverySeverity+Style.swift`, `String+Formatting.swift` — view/formatting helpers. | — |

### Python bridge (`bridge/`)

| File | Responsibility |
|---|---|
| `macphone_netsim_bridge.py` | The emulator side. Connects to `BLEBridgeServer` (127.0.0.1:8765), reads the GATT mirror, builds matching Bumble services, and advertises a virtual peripheral `MacPhone Bridge` on `android-netsim`. Forwards reads/writes to the real device on demand and auto-subscribes every notify/indicate characteristic so notifications stream into the emulator. Resolves netsim's gRPC port from `netsim.ini` across several temp dirs. |
| `mock_bridge_server.py` | A fake GATT source (battery + Xiaomi-style service) that stands in for the MacPhone app, so the netsim path can be proven without a real device or the Swift app. |
| `netsim_central_probe.py` | An automated BLE central on netsim that connects + reads + subscribes — acts like the Android app under test in the self-contained demo. |
| `run_bridge.sh` / `run_demo.sh` | Convenience launchers (Test B: real device through the app; Test A: self-contained proof). |

---

## Subsystem 1 — Fleet orchestration

### Discovery (read path)

```
DeviceStore.refresh()
   ├─ async let  AndroidOrchestrator.discover()
   │     ├─ AndroidSDK.locate()  → emulator/adb paths
   │     ├─ emulator -list-avds          → AVD definitions
   │     ├─ adb devices -l               → running serials (emulator-5554, …)
   │     └─ merge: adb -s <serial> emu avd name → fold running AVD onto its definition
   └─ async let  IOSSimulatorOrchestrator.discover()
         └─ xcrun simctl list devices --json → flatten by runtime, drop unavailable
   →  devices: [MobileDevice]  +  issues: [DiscoveryIssue]   (sorted, surfaced in UI)
```

All process spawning funnels through `CommandRunner` (an actor) which drains both pipes concurrently and times out. Missing tools become non-fatal `DiscoveryIssue`s, not crashes — the app still shows the other platform.

### Lifecycle (control path)

```
DeviceStore.boot / coldBoot / stop / wipe(device)
   └─ perform(): mark busy → DeviceControlService.<action>(device) → sleep 2s → refresh()
```

`DeviceControlService` branches on `device.platform`:

- **iOS:** `xcrun simctl boot|shutdown|erase <udid>` (treating "already in that state" as benign), and `open -a Simulator` to surface the UI on boot.
- **Android:** the emulator is a long-lived process, so boot uses `launchDetached` with `emulator -avd <name>` plus optional `-no-window`/`-no-boot-anim` (headless) and `-no-snapshot-load` (cold). Stop is `adb -s <serial> emu kill`. Wipe relaunches cold with `-wipe-data` (a running AVD can't be wiped in place).

State changes are asynchronous on the emulator/simulator side, so the store waits ~2s and re-runs discovery rather than mutating optimistically.

---

## Subsystem 2 — The no-dongle BLE bridge

### Why it exists / why it works

macOS owns the internal Bluetooth controller's HCI. There is **no supported way** to hand that raw HCI link to the emulator's virtual controller (netsim/RootCanal). The only dongle-free option is to bridge one level up — at the **GATT/application layer**. This is sufficient for e-scooters specifically because their security lives in the **application layer** (NinebotCrypto: SHA-1/AES/CRC over 20-byte chunks), not in BLE link-layer pairing/bonding. A GATT byte mirror therefore needs no link-layer bond to cross the bridge.

### Data / control flow

```
Real BLE device ──BLE──▶ BLEBridgeService (CoreBluetooth central, Mac internal radio)
                              │  rebuildGATT on discovery; per-value updates on notify
                              ▼
                    BLEBridgeServer  (127.0.0.1:8765, newline JSON, Network.framework)
                              │  broadcasts state/gatt/value;  receives read/subscribe/write
                              ▼
                 macphone_netsim_bridge.py (Bumble)
                              │  builds matching Bumble services; auto-subscribes notify/indicate
                              ▼
                    android-netsim ──▶ Android app talks GATT to "MacPhone Bridge"
```

Flow notes from the code:

- **Late-join replay.** `BLEBridgeServer.onClientConnected` lets `BLEBridgeService` re-broadcast the current `state` + full `gatt` snapshot, so a bridge that connects after the device is already connected still gets the GATT.
- **GATT rebuild vs. value update.** The full service tree is rebuilt only on structural discovery (`rebuildGATT`); individual notifications update one characteristic in place (`updateValue`) and broadcast a single `value` event — keeping SwiftUI identities stable and the wire chatter small.
- **Auto-subscribe.** On the emulator side, every notify/indicate characteristic is subscribed automatically, so the real device's stream flows into the emulator without the app asking first.
- **Reads/writes** from the Android app are translated to `read`/`write` commands, executed against the real peripheral, and the result streamed back as a `value` event.

### Bridge wire protocol

One JSON object per line, UTF-8, newline-delimited, on `127.0.0.1:8765`.

**Mac → client (events, emitted by `BLEBridgeServer.broadcast`):**

```json
{"type":"state","value":"connected"}
{"type":"gatt","services":[{"uuid":"…","characteristics":[{"uuid":"…","properties":["read","notify"]}]}]}
{"type":"value","characteristic":"…","value":"<hex>"}
```

**client → Mac (commands, parsed by `BLEBridgeServer.parseCommand`):**

```json
{"cmd":"read","characteristic":"…"}
{"cmd":"subscribe","characteristic":"…","enabled":true}
{"cmd":"write","characteristic":"…","value":"<hex>","withResponse":true}
```

Property labels in the `gatt` event are: `read`, `write`, `writeNR`, `notify`, `indicate`. Values are lowercase hex strings.

### netsim discovery (the TMPDIR gotcha)

The emulator writes `netsim.ini` (with `grpc.port=…`) into **its own** `TMPDIR`, which differs depending on whether it was launched from a terminal or from a GUI app — launchd hands GUI apps a per-app `TMPDIR`. So `macphone_netsim_bridge.py` searches several candidate dirs (`$TMPDIR`, `~/Library/Caches/TemporaryItems`, per-app `/var/folders/*/*/T`, `/tmp`) and passes an explicit `android-netsim:127.0.0.1:<port>` rather than relying on a matching `TMPDIR`. Override with `MACPHONE_NETSIM_TRANSPORT`.

---

## State and concurrency

- `DeviceStore`, `BLEBridgeService`, `BLEBridgeServer` are all `@Observable`; the two BLE types are `@MainActor`. CoreBluetooth is created with a `nil` delegate queue so its callbacks land on the main queue, matching `@MainActor`; delegate methods are `nonisolated` and hop back via `Task { @MainActor in … }`.
- `CommandRunner` is an `actor`; the actual `Process` work runs in a `Task.detached(.utility)` so the main actor never blocks on a child process. `DataBox` is an `NSLock`-guarded accumulator because `readabilityHandler` fires on an arbitrary queue.
- Discovery fans out with `async let` (Android + iOS in parallel); control actions serialize per device via a `busyDeviceIDs` set.

---

## Key constraints / hard truths

1. **Internal HCI is not passthroughable.** macOS owns the built-in controller's HCI; you cannot hand that raw link to the emulator's virtual controller. The bridge therefore works at the GATT layer, not the link layer.
2. **CoreBluetooth is BLE-only.** Bluetooth **Classic** (BR/EDR) — speakers, car stereos, classic headsets — is invisible to the Mac side and cannot be bridged. Good targets: e-scooters, fitness bands, smart locks, BLE beacons, a BLE-peripheral app.
3. **GATT-layer mirror, not link-layer bond.** Apps that require true link-layer bonding/encryption would still need a real radio on the emulator side. This is fine for Xiaomi/Ninebot (app-layer crypto), not universal.
4. **Connect from a BLE client, not Android Settings.** *Settings → Pair new device* is Classic bonding and hangs on a BLE GATT peripheral; use nRF Connect or `netsim_central_probe.py`.
5. **No iPhone Bluetooth parity.** The iOS Simulator is not a real iPhone for Bluetooth-heavy testing.
6. **Localhost only.** The bridge server binds `127.0.0.1` exclusively.

See [`docs/TECHNICAL_PLAN.md`](docs/TECHNICAL_PLAN.md) § "Hard Technical Truths" for the full list and sources.

---

## Build & run

The app is a plain SwiftPM executable; there is no `.xcodeproj`.

```sh
# build, assemble MacPhone.app under dist/, launch it
./script/build_and_run.sh

# variants
./script/build_and_run.sh --debug      # lldb
./script/build_and_run.sh --logs       # launch + stream os_log for the process
./script/build_and_run.sh --verify     # launch and assert the process is alive
```

`script/build_and_run.sh` generates the Xcode project with XcodeGen, builds the
native app through `xcodebuild`, and launches the resulting `.app`. This keeps
local development aligned with CI, Sparkle packaging, asset catalogs, and the
current Apple SDK.

For the BLE bridge, set up the Python side once and run a test:

```sh
cd bridge
python3 -m venv .venv && .venv/bin/python -m pip install bumble
./run_demo.sh      # Test A: self-contained netsim proof, no real device
./run_bridge.sh    # Test B: bridge a real device connected via the MacPhone app
```

See [`bridge/README.md`](bridge/README.md) for the full Test A / Test B runbook.

---

## When this document goes stale

Update it when you:

- Add a new service under `Sources/MacPhone/Services/` or change a service's contract.
- Change the bridge wire protocol (the JSON shapes).
- Change how the fleet is discovered or controlled (new tool, new flag).
- Add a `DeviceSection` or restructure the UI shell.
- Touch the netsim discovery / TMPDIR logic.

Treat the diagrams and the protocol block as load-bearing. If the code and a diagram disagree, the diagram is wrong, not the code.
