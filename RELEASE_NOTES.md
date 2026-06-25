# MacPhone release notes

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
