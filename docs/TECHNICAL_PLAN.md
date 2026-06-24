# MacPhone Technical Plan

## Product Positioning

MacPhone is a native macOS app that gives one place to create, launch, group, inspect, and automate many mobile environments:

- Android Emulator instances.
- iOS Simulator instances.
- Connected real Android and iOS devices.
- BLE-connected accessories through a macOS bridge.
- Device profiles for screen size, OS version, locale, network, sensors, and test presets.

Do not market the first versions as a complete iPhone emulator. iOS virtualization is controlled by Apple through Xcode Simulator and physical devices. MacPhone should wrap and automate Apple's supported tools rather than pretending to replace them.

### Primary Goal: Native Multi-Phone Fleet

The core product is a fleet manager: run and orchestrate **many** phones at once on
the Mac, using only native/first-party tooling — no third-party emulators (BlueStacks,
Genymotion, etc.). Bluetooth/BLE accessory bridging (e.g. e-scooter) is one optional
feature on top, not the product.

What "native on the Mac" actually supports (researched June 2026):

| Platform | Engine | Native acceleration | Many instances | Headless | Control surfaces |
|----------|--------|--------------------|----------------|----------|------------------|
| Android  | Google Android Emulator (QEMU) | Hypervisor.framework, `arm64-v8a` images on Apple Silicon (boot <15s) | Yes — ports 5554–5585, console=even/adb=odd, localhost-only, token in `~/.emulator_console_auth_token` | Yes (`-no-window`, since emulator 28.0.25) | `emulator` CLI, `adb`, telnet console, gRPC (`-grpc 5556`) |
| iOS      | Apple Xcode Simulator | Native Apple-only | Yes — concurrent boots | N/A (UI only) | `xcrun simctl` (list/clone/boot/shutdown/erase/install/launch) |

Apple's `Virtualization.framework` is native but only virtualizes **macOS and Linux**
guests, not Android — so it is out of scope for the phone fleet (a Linux host running
android-x86 is heavier and slower than the official emulator and offers no advantage).

Implication for the fleet model: "many phones" = many `simctl` simulators + many
Android Emulator AVDs, each a separate OS process the app launches, tracks by port,
controls, and previews. Scale is bounded by RAM/CPU (≈16 GB RAM for comfortable
multi-device runs), not by an API limit.

Sources:
- https://developer.android.com/studio/run/emulator-commandline
- https://developer.android.com/studio/run/emulator-console
- https://developer.android.com/studio/releases/emulator
- https://developer.apple.com/documentation/virtualization

## Current Research Baseline

### Apple APIs

Use `CoreBluetooth` for supported BLE work on macOS. Apple describes Core Bluetooth as the framework for apps to communicate with Bluetooth LE and Basic Rate devices.

Source: https://developer.apple.com/documentation/corebluetooth/

For sandboxed macOS apps, include the Bluetooth entitlement:

Source: https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.bluetooth

`IOBluetooth` exists and supports user-space Bluetooth device access through C and Objective-C APIs, but it is not a stable public Raw-HCI product layer.

Source: https://developer.apple.com/documentation/iobluetooth

Apple's retired iOS Simulator Bluetooth technote is still useful as evidence for the architecture problem: even with built-in Mac Bluetooth, the old simulator path required an external BLE USB adapter because the system Bluetooth driver owns the built-in HCI.

Source: https://developer.apple.com/library/archive/technotes/tn2295/_index.html

Low-level macOS HCI/ACL access has been demonstrated through reverse engineering, but the relevant APIs are undocumented/private and not suitable as an MVP dependency.

Source: https://wisec2020.ins.jku.at/proceedings/wisec20-1000.pdf

### Android Emulator Bluetooth

Google Bumble documents Android Emulator Bluetooth support around Netsim/Root Canal and HCI bridging. The important path is:

- Virtual Bluetooth controllers through Netsim.
- Bumble connected to Android Emulator using `android-netsim`.
- HCI bridge from Android Emulator to a physical Bluetooth controller, usually a USB Bluetooth dongle.

Source: https://google.github.io/bumble/platforms/android.html

Bumble warns that the older `android-emulator` transport is obsolete and recent emulator setups should use `android-netsim`.

Source: https://google.github.io/bumble/transports/android_emulator.html

AOSP Cuttlefish uses Rootcanal for Bluetooth simulation and control.

Source: https://source.android.com/docs/devices/cuttlefish/bluetooth

The Bumble source notes that internal Bluetooth interfaces tend to be locked down by the OS, and a dedicated USB dongle is the easiest physical-radio path.

Source: https://android.googlesource.com/platform/external/python/bumble/

## Hard Technical Truths

1. The MacBook's internal Bluetooth controller cannot be cleanly passed through to many Android Emulator or iOS Simulator instances.
2. A Swift app can use CoreBluetooth for BLE scanning, connecting, GATT reads/writes, and notifications.
3. A Swift app should not rely on private Raw-HCI/ACL APIs for a shipped product.
4. iOS Simulator cannot be treated as a real iPhone for Bluetooth-heavy testing. Bluetooth flows need either a real iPhone or a proxy layer in the app.
5. Android Emulator Bluetooth is possible for research and tests, but real physical radio passthrough is most practical with an external controller.
6. Many simultaneous "phones" can be orchestrated, but many simultaneous real Bluetooth radios require many real radio controllers or a proxy/mock model.

## No-External-Hardware E-Scooter Path (implemented)

Goal: connect an Android emulator running on the Mac to a real BLE e-scooter
(Xiaomi/Ninebot family) without any USB Bluetooth dongle.

Why a raw passthrough is impossible: macOS owns the internal controller's HCI.
There is no supported way to hand that raw HCI link to the emulator's virtual
controller (netsim/RootCanal). The only supported, dongle-free option is to
bridge one level up — at the GATT/application layer.

This works for e-scooters specifically because their security lives in the
**application layer** (NinebotCrypto: SHA-1/AES/CRC over 20-byte chunks), not in
BLE link-layer pairing/bonding. A GATT byte mirror is therefore sufficient; no
link-layer bond has to cross the bridge.

Data path:

```text
Real scooter  ──BLE──▶  Mac CoreBluetooth central (internal radio, no dongle)
                              │
                              ▼
                  BLEBridgeServer  (127.0.0.1, newline-delimited JSON)
                              │
                              ▼
        Bumble virtual peripheral on android-netsim  ──▶  Android app under test
```

Implementation in this repo:

- `BLEBridgeService` — CoreBluetooth central: scan/connect/discover/read/write/
  notify on the Mac's built-in radio. Drives the live Bluetooth UI.
- `BLEBridgeServer` — localhost TCP server (Network framework) that re-publishes
  the connected peripheral's GATT and streams notifications, and accepts
  read/subscribe/write commands back. Bound to 127.0.0.1 only.
- Emulator side (external, not in this package): a Bumble script on
  `android-netsim` that consumes the JSON feed and presents the same GATT to the
  Android app. The app talks "Bluetooth" to a local virtual peripheral; the Mac
  relays the bytes to/from the physical scooter.

Bridge wire protocol (one JSON object per line, UTF-8):

```text
Mac → client:  {"type":"state","value":"connected"}
               {"type":"gatt","services":[{"uuid":"…","characteristics":[{"uuid":"…","properties":["read","notify"]}]}]}
               {"type":"value","characteristic":"…","value":"<hex>"}
client → Mac:  {"cmd":"read","characteristic":"…"}
               {"cmd":"subscribe","characteristic":"…","enabled":true}
               {"cmd":"write","characteristic":"…","value":"<hex>","withResponse":true}
```

Limitation: this mirrors GATT, not the link layer. Apps that require true
link-layer bonding/encryption (not the case for Xiaomi/Ninebot app-layer crypto)
would still need a real radio on the emulator side.

## Recommended Architecture

```text
MacPhone.app
  UI: SwiftUI
  Core: Swift actor-based device orchestration
  Services:
    AndroidDeviceService
    IOSSimulatorService
    RealDeviceService
    BLEBridgeService
    AutomationService
    ProfileStore

Android Emulator(s)
  Controlled by:
    adb
    emulator command-line flags
    emulator console
    optional gRPC/Netsim integration

iOS Simulator(s)
  Controlled by:
    xcrun simctl
    xcodebuild for app builds/tests

BLE Bridge
  Swift/CoreBluetooth
  Local WebSocket or Unix domain socket API
  Optional app SDKs for Android/iOS
  Optional hook adapters for research-only third-party app experiments
```

## Implementation Tracks

### Track 1: Native macOS Shell

Language: Swift + SwiftUI.

Build:

- Sidebar with device groups.
- Device grid/list with status, OS version, runtime, boot state, and port.
- Detail inspector for logs, installed apps, screenshots, and actions.
- Local project model stored as JSON or SQLite.

Initial commands:

- Discover Android SDK path.
- List AVDs.
- Start/stop Android Emulator instances.
- Run `adb devices`.
- Capture screenshots and logs.
- Discover Xcode path.
- Run `xcrun simctl list --json`.
- Boot/shutdown iOS simulators.
- Install/launch apps on booted simulators.

### Track 2: Android Device Lab

Language: Swift for orchestration, shell process wrappers for Android tools.

Features:

- AVD creation from templates.
- Launch many emulators with stable port assignment.
- Per-device labels, groups, boot profiles.
- Install APK/AAB-derived APKs.
- Launch app by package/activity.
- Collect logcat.
- Screenshot and screen recording.
- Network shaping through emulator console where supported.
- Sensor/location presets.

Bluetooth levels:

- Level A: no Bluetooth, only mocked app transport.
- Level B: Bumble/Netsim virtual peripherals.
- Level C: Bumble HCI bridge to external controller.
- Level D: research-only host internal controller experiments.

### Track 3: iOS Device Lab

Language: Swift orchestration around Xcode tools.

Features:

- Simulator runtime/device discovery.
- Boot/shutdown/erase.
- Install `.app`.
- Launch by bundle ID.
- Screenshot/video/log capture.
- Multiple simulator windows.
- Test runner integration through `xcodebuild test`.

Bluetooth levels:

- Level A: app-integrated BLE proxy SDK.
- Level B: CoreBluetooth mock/passthrough library for simulator builds.
- Level C: real iPhone support for true hardware validation.

Do not promise direct iOS Simulator Bluetooth hardware parity.

### Track 4: BLE Bridge

Language: Swift first.

Core APIs:

- `CBCentralManager`
- `CBPeripheral`
- `CBService`
- `CBCharacteristic`
- `CBPeripheralDelegate`
- `CBCentralManagerDelegate`

Bridge API:

```text
scan(filter)
connect(deviceId)
discoverServices(deviceId)
read(serviceUuid, characteristicUuid)
write(serviceUuid, characteristicUuid, data, withResponse)
subscribe(serviceUuid, characteristicUuid)
disconnect(deviceId)
```

Transport:

- Prefer Unix domain socket for local SDK/hook integrations.
- WebSocket is easier for Android Emulator clients.
- JSON is fine for MVP; Protobuf/gRPC can come later.

Security:

- Bind to localhost only.
- Require per-session token.
- Show active BLE connections in the MacPhone UI.
- Never silently connect to BLE devices in the background.

### Track 5: App SDKs

For apps we control, do not hook. Use explicit SDKs.

Android:

- Kotlin library implementing a `BleTransport` interface.
- Real Android implementation uses `BluetoothGatt`.
- Emulator implementation forwards to MacPhone Bridge.

iOS:

- Swift package wrapping BLE access behind a protocol.
- Device implementation uses CoreBluetooth.
- Simulator implementation forwards to MacPhone Bridge.

This is the cleanest way to support BLE without external hardware for owned apps.

### Track 6: Hooking Research

This is optional and should live outside the core app until proven.

Android options:

- Frida
- Xposed/LSPosed
- Rooted emulator images

Hook targets:

- `BluetoothAdapter`
- `BluetoothLeScanner`
- `BluetoothGatt`
- `BluetoothGattCallback`
- `BluetoothDevice`

Risks:

- Fragile against app updates.
- App-specific behavior.
- Pairing and bonding are hard.
- Anti-tamper can block hooks.
- Not a stable product foundation.

iOS Simulator options:

- Runtime swizzling for CoreBluetooth-like APIs in simulator builds.
- Similar pattern to existing BLE proxy projects that forward CoreBluetooth calls to a macOS helper.

This only works for apps we can modify/link. It is not a general third-party iPhone app solution.

## Low-Level Bluetooth Strategy

Do not start with private HCI.

Public product path:

```text
Swift CoreBluetooth -> BLE Bridge -> Emulator/Simulator client SDK
```

Research path:

```text
Objective-C++/C -> private IOBluetooth symbols / IOKit -> HCI/ACL experiments
```

Use the research path only to learn feasibility. Keep it in a separate lab target because it may break across macOS versions and can conflict with system Bluetooth.

## Suggested Repository Layout

```text
MacPhone/
  README.md
  docs/
    TECHNICAL_PLAN.md
    RESEARCH_NOTES.md
  apps/
    MacPhoneApp/
  packages/
    MacPhoneCore/
    BLEBridge/
    AndroidOrchestrator/
    IOSOrchestrator/
  sdk/
    android/
    ios/
  labs/
    android-bumble/
    ios-ble-proxy/
    macos-hci-research/
```

## MVP Scope

MVP 0:

- SwiftUI app shell.
- List Android AVDs.
- List iOS simulators.
- Boot/stop devices.
- Show live state.

MVP 1:

- Install/launch apps.
- Screenshot/log capture.
- Device groups.
- Basic automation queue.

MVP 2:

- BLEBridgeService with CoreBluetooth scan/connect/read/write/notify.
- Local WebSocket API.
- Sample Android app using bridge transport.
- Sample iOS simulator app using bridge transport.

MVP 3:

- Bumble/Netsim experiment panel.
- Virtual BLE peripheral simulator.
- Documentation for when a USB Bluetooth dongle is required.

MVP 4:

- Real-device support.
- Android `adb` physical device management.
- iOS physical device management through Xcode tools.

## Immediate Next Steps

1. Scaffold Swift package/app structure.
2. Implement command runner with streaming output and cancellation.
3. Implement Android SDK/AVD discovery.
4. Implement `xcrun simctl list --json` parsing.
5. Build the first MacPhone UI with Android/iOS inventory.
6. Add BLEBridge proof of concept in a separate Swift package.
7. Build one Android sample app that calls MacPhone over WebSocket for BLE.
8. Decide after the BLE proof whether hooking research is worth doing.

## Non-Goals For The First Version

- Full custom Android OS emulator.
- Full iPhone emulator.
- App Store distribution.
- Private macOS HCI access as a required feature.
- Unmodified third-party app Bluetooth support as a promise.
- Many simultaneous real BLE radios without external hardware.
