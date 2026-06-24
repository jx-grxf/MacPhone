---
tags: [pitfall, netsim, bridge, tmpdir, critical]
---

# netsim TMPDIR Discovery

## Problem

The Android Emulator writes `netsim.ini` (containing `grpc.port=<port>`) into **its own `TMPDIR`**. That directory differs depending on how the emulator was launched: a terminal-launched emulator and a GUI-app-launched one get **different** TMPDIRs, because launchd hands GUI apps a per-app `TMPDIR` (`/var/folders/xx/yyy/T/`). So a bridge process that only checks its own `$TMPDIR` may never find `netsim.ini` and fail to locate netsim's gRPC port.

## Where in code

`bridge/macphone_netsim_bridge.py`, `resolve_netsim_transport()`:

1. If `MACPHONE_NETSIM_TRANSPORT` is set, honour it verbatim.
2. Otherwise search several candidate dirs for `netsim.ini`:
   - `$TMPDIR`
   - `~/Library/Caches/TemporaryItems`
   - `/var/folders/*/*/T` (per-app launchd temp dirs, globbed)
   - `/tmp`
3. Parse `grpc.port=` and return an **explicit** `android-netsim:127.0.0.1:<port>` rather than relying on a matching TMPDIR.

## Rule

Never assume the bridge's `$TMPDIR` matches the emulator's. Pass an explicit `host:port` to Bumble. If discovery still fails, pin it with `MACPHONE_NETSIM_TRANSPORT=android-netsim:127.0.0.1:<port>`.

See [[netsim Bridge (Python)]], [[BLE Bridge Subsystem]].
