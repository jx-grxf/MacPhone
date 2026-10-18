# MacPhone release notes

## 0.3.1

### Fixed

- The Emulator step of the Bluetooth bridge shows "App connected" only while an app in the emulator is connected to the mirrored device.

### Compatibility

- macOS 14 or later, Apple silicon.
- Not notarized yet. On first launch, open System Settings → Privacy & Security and choose Open Anyway.

## 0.3.0

### New

- The Bluetooth bridge shows each step from device to emulator with its own status, and tells you which one is missing.
- Simulators for every Apple platform, grouped by device type, with search and a running-only filter.
- Drop an .app or .apk on a running device to install it. Open URLs, take screenshots, switch light and dark mode, and set a clean 9:41 status bar from the device menu.
- Rename, duplicate, erase and delete simulators and emulators.
- New emulators use Android 14 to 17 images.
- Setup finds the Homebrew Android tools and lets you pick an SDK folder in Settings.

### Fixed

- The bridge runtime now installs Bumble with the gRPC support netsim needs. Before, mirroring failed on a fresh Mac.
- Notifications keep flowing after the emulator app reconnects.
- Stop works in every state, including while a connection or reconnect is pending.
- The Setup tab no longer freezes when several simulator runtimes are installed.
- Malformed bridge messages can no longer crash the app, and only the bridge MacPhone started can talk to the connected device.
- Emulator start failures and a stopped bridge show the reason.
- Erasing a running emulator waits for it to shut down first.
- MacPhone only changes hardware settings of emulators it created.

### Removed

- The virtual scooter profiles and the Ninebot test fixture.

### Compatibility

- macOS 14 or later, Apple silicon.
- Not notarized yet. On first launch, open System Settings → Privacy & Security and choose Open Anyway.

## 0.2.1

### Fixed

- Restored the selectable virtual scooter catalog that was accidentally omitted
  from the v0.2.0 build. The Bluetooth tab now offers Xiaomi M365, Pro 2, 1S,
  and a low-battery/fault profile from the Test Scooter menu.
- Restored the encrypted multi-model Ninebot test fixture and launcher for G2,
  G3, G30, E/ES/F models, and ZT3 Pro.
- Virtual scooter tuning writes persist and round-trip for KERS, cruise, tail
  light, and custom-firmware field weakening.

### Compatibility

- macOS 14 or later. Apple silicon.
- Ad-hoc signed developer preview — right-click the app and choose *Open* on first
  launch, or open the DMG and drag MacPhone to Applications.

## 0.2.0

### Highlights

- **Multi-profile virtual scooters.** The in-app test scooter is now a catalog
  of selectable Xiaomi models — M365 (stock), Pro 2 (custom firmware with field
  weakening), 1S, and a low-battery/fault profile — each with profile-driven
  register banks. Tuning writes (KERS, cruise, tail light, field weakening)
  persist and round-trip on subsequent reads.
- **Encrypted Ninebot test fixture.** Ninebot Max G2 emulation restored and
  expanded into a 13-model fixture (G2, G3, G30, E22, E25, E45, ES1–4, F65,
  F2/F2 Pro/F2 Plus, ZT3 Pro). Full NinebotCrypto session handshake with
  per-model register banks, write persistence, and a `run_ninebot.sh [model]`
  launcher.
- **No hardware required.** Both fixture families let E-Tune exercise every
  supported scooter protocol end-to-end on the Android emulator without
  physical devices or BLE dongles.


### Compatibility

- macOS 14 or later. Apple silicon.
- Ad-hoc signed developer preview — right-click the app and choose *Open* on first
  launch, or open the DMG and drag MacPhone to Applications.
