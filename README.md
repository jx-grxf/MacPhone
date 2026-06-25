<div align="center">

# MacPhone

A native macOS device lab — run and control many Android emulators and iOS simulators from one Mac, and bridge a **real** Bluetooth LE device straight into an emulator so on-device apps can talk to hardware the Mac is connected to.

[![CI](https://github.com/jx-grxf/MacPhone/actions/workflows/ci.yml/badge.svg)](https://github.com/jx-grxf/MacPhone/actions/workflows/ci.yml)
![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-111827)
![Swift](https://img.shields.io/badge/swift-6.0-orange?logo=swift&logoColor=white)
![SwiftUI](https://img.shields.io/badge/UI-SwiftUI-0A84FF)
![License](https://img.shields.io/badge/license-MIT-blue)

[Build](#build) · [Architecture](ARCHITECTURE.md) · [BLE bridge](#the-ble-bridge) · [Technical plan](docs/TECHNICAL_PLAN.md) · [Release](RELEASE.md)

</div>

> [!TIP]
> The hard part of testing a hardware-talking mobile app isn't the app — it's getting a real BLE
> device in front of code running inside an emulator. MacPhone connects to the device over the
> Mac's own radio and re-publishes its exact GATT tree on the emulator's virtual controller, so the
> app under test sees the real services, characteristics and advertisement with no dongle.

## What it does

- **Manages Android emulators.** Discover, provision and launch AVDs; one panel for many devices.
- **Manages iOS simulators.** Drives the Xcode simulator toolchain for parallel iOS environments.
- **Bridges real Bluetooth LE into the emulator.** Connects to a physical BLE device over
  CoreBluetooth, mirrors its full GATT tree (services, characteristics, advertisement) and
  re-broadcasts it on the Android emulator's `netsim` controller via a Bumble virtual peripheral.
- **Forwards live traffic both ways.** Reads and writes from the emulated app are forwarded to the
  real device; every notify/indicate characteristic is auto-subscribed so notifications stream back.
- **Keeps sessions clean.** Disconnects stale emulator clients, requests a fresh real-device session
  after each disconnect, and tears the bridge down with its parent process — no orphaned peripherals.

## The BLE bridge

```
Real BLE device
    │  Bluetooth LE (Mac internal radio)
    ▼
MacPhone.app ──CoreBluetooth central──┐
    │                                 │
    ▼  127.0.0.1:8765 (newline JSON)  │
bridge (Bumble) ──peripheral──▶ android-netsim ──▶ Android app under test
```

The Mac app publishes the live GATT mirror over a localhost JSON socket; the Python bridge
(`bridge/`) re-publishes it as a Bumble peripheral on `netsim`. The app under test scans and
connects exactly as it would to the real device. See [`bridge/README.md`](bridge/README.md).

## Build

Requires macOS 14+ and the current stable Xcode 26 toolchain.

```bash
git clone https://github.com/jx-grxf/MacPhone.git
cd MacPhone
brew install xcodegen
./script/build_and_run.sh
```

The BLE bridge runs from its own virtualenv:

```bash
cd bridge
python3 -m venv .venv && source .venv/bin/activate
pip install bumble
python3 macphone_netsim_bridge.py
```

## Architecture

- `Sources/MacPhone/Services/` — orchestrators (Android/iOS), the CoreBluetooth bridge service and
  localhost server, the netsim bridge process supervisor, device control and setup.
- `Sources/MacPhone/Views/` — SwiftUI UI (sidebar, detail, Bluetooth bridge, provisioning, setup).
- `Sources/MacPhone/Stores/` + `Models/` — device store and BLE/device models.
- `bridge/` — the Python/Bumble netsim peripheral that mirrors the real device into the emulator.

Full module map in [ARCHITECTURE.md](ARCHITECTURE.md).

## License

MIT — see [LICENSE](LICENSE).
