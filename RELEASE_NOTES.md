# MacPhone release notes

## 0.1.0

First public preview of MacPhone — a native macOS device lab that bridges a real
Bluetooth LE device into Android emulators and iOS simulators.

### Highlights

- **Auto-updates via Sparkle.** MacPhone now checks for updates in the background
  and on launch, with a manual *Check for Updates…* in the app menu and a
  Stable/Beta channel toggle in Settings → Updates.
- **One-click Pixel + BLE Radar.** Setup has a Quick start that creates a
  Play-enabled Pixel emulator, boots it, and installs the open-source BLE Radar
  scanner — ready to connect to the bridged device immediately.
- **Install BLE Radar on demand.** Any running Android emulator can get BLE Radar
  installed from its row menu.

### Compatibility

- macOS 14 or later. Apple silicon.
- Ad-hoc signed developer preview — right-click the app and choose *Open* on first
  launch, or open the DMG and drag MacPhone to Applications.
