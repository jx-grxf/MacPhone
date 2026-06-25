# MacPhone release notes

## 0.1.1

### Highlights

- **Optional test devices.** Enable *Test Devices* in Settings to show the
  virtual Xiaomi M365 scooter on the Bluetooth screen.
- **M365 protocol testing.** The in-app scooter exposes its Nordic UART GATT
  service, model advertisement, telemetry registers, and read replies for
  Android emulator testing with apps such as XiaoDash.
- **Hidden by default.** Production BLE workflows remain uncluttered until test
  devices are explicitly enabled.
- **Much faster Android emulators.** Emulators now render through the host Metal
  GPU instead of silently falling back to software (SwiftShader), which had been
  pegging the CPU and making running VMs crawl. Headless boots keep the software
  path where no host surface exists.

## 0.1.0

First public preview of MacPhone — a native macOS device lab for Android
emulators and iOS simulators, including a real Bluetooth LE bridge for Android.

### Highlights

- **Auto-updates via Sparkle.** MacPhone now checks for updates in the background
  and on launch, with a manual *Check for Updates…* in the app menu and a
  Stable/Beta channel toggle in Settings → Updates.
- **Fast Android emulators by default.** New and existing AVDs use
  automatic hardware CPU/GPU acceleration and sensible CPU/RAM defaults.
- **One-click iOS simulators.** The iOS screen can download Apple’s current
  Simulator runtime, create an iPhone with `simctl`, and boot it immediately.
- **No bundled Android apps.** MacPhone creates clean Android emulators and does
  not preinstall third-party scanner applications.

### Compatibility

- macOS 14 or later. Apple silicon.
- Ad-hoc signed developer preview — right-click the app and choose *Open* on first
  launch, or open the DMG and drag MacPhone to Applications.
