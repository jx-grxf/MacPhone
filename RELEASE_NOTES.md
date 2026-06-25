# MacPhone release notes

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
