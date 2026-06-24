# Release readiness

Status of the MacPhone app for a first public build. **Not yet released.**

## Build & run

```bash
swift build                      # compile
./script/build_and_run.sh run    # package dist/MacPhone.app (with Info.plist) and launch
./script/build_and_run.sh --verify
```

The packaging script produces a real `.app` with `Info.plist` carrying
`NSBluetoothAlwaysUsageDescription`, version metadata (`CFBundleShortVersionString` /
`CFBundleVersion`, override via `MACPHONE_VERSION` / `MACPHONE_BUILD`), and the
developer-tools category.

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

## Remaining before an actual release

1. **Bundle the bridge runtime for distribution.** The app locates `bridge/` by walking up
   from its own location, so it works when run from the repo (`dist/MacPhone.app` beside
   `bridge/`). A copy dragged to `/Applications` will not find `bridge/`. To ship
   standalone: copy `bridge/*.py` into `Contents/Resources/bridge`, have
   `NetsimBridgeProcess.bridgeDirectory()` check `Bundle.main.resourceURL` first, and
   relocate the Python venv to `~/Library/Application Support/MacPhone/bridge-venv`
   (an app bundle in `/Applications` is read-only, so the venv cannot live inside it).
   Until then, set `MACPHONE_BRIDGE_DIR` to point at a writable `bridge/` checkout.
2. **Code signing & notarization** for distribution outside the dev machine.
3. **App icon** (`CFBundleIconFile` / `.icns`) — currently unset.
