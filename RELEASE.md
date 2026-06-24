# Release readiness

Status of the MacPhone app for a first public build.

## Build & run

```bash
./script/build_and_run.sh build-only
./script/build_and_run.sh
```

The XcodeGen project embeds Sparkle, the app icon, the Python bridge scripts,
version metadata, and the Bluetooth permission description.

## Fixed in this pass

Backend
- Provisioning now **fails loudly** when SDK license acceptance or the
  `platform-tools`/`emulator` install fails, instead of creating an AVD that can't boot
  (`AndroidProvisioner`).
- External processes (`sdkmanager`, `avdmanager`, probes) now honour Swift task
  cancellation and are terminated when the caller is cancelled (`CommandRunner`).
- The netsim bridge process clears its pipe handler on stop and distinguishes a clean
  stop from an unexpected crash (`NetsimBridgeProcess`).
- The local bridge TCP server bounds its per-line buffer so a misbehaving client can't
  grow memory without limit (`BLEBridgeServer`).

Frontend / UX
- **Wipe Data** is gated behind a confirmation dialog naming the device.
- **Disconnect & Scan** actually returns to a live scan instead of an empty list.
- Setup now checks the **BLE bridge runtime** (Python venv + Bumble) and offers a
  one-click "Set up bridge runtime" that creates `bridge/.venv` and installs Bumble — so
  Setup no longer reports "ready" and then fails at mirror time.
- The provision sheet is resizable, has **Copy Log**, and a **Boot after creating** toggle.
- The bridge subtitle tells users to use a BLE client (nRF Connect), not Android Settings.

## Distribution

- Stable tags use `vX.Y.Z`; beta tags use `vX.Y.Z-beta.N`.
- Stable clients read the latest stable release appcast.
- Beta clients read the moving `beta` release, whose appcast retains both stable
  and beta items so beta users can move back onto a newer stable build.
- Release builds currently use ad-hoc signing. Developer ID signing and
  notarization activate when the corresponding `MACPHONE_*` secrets are set.
- The bridge scripts ship in the app. Its writable Bumble environment is created
  under `~/Library/Application Support/MacPhone/bridge-runtime`.
