#!/usr/bin/env python3
"""
MacPhone netsim bridge — the emulator side of the BLE bridge.

Reads the live GATT mirror MacPhone publishes over its localhost BLEBridgeServer
(127.0.0.1:8765, one JSON object per line) and re-publishes it as a Bumble virtual
peripheral on the Android emulator's netsim controller. The Android app under test
then sees the same services/characteristics as the real BLE device the Mac is
connected to over its internal radio — no external Bluetooth dongle involved.

    Real BLE device
        │  (Bluetooth LE, Mac internal radio)
        ▼
    MacPhone.app  ──CoreBluetooth central──┐
        │                                  │
        ▼  127.0.0.1:8765 (newline JSON)   │
    THIS SCRIPT  ──Bumble peripheral──▶  android-netsim ──▶  Android app

Run order:
    1. Start the Android emulator (so netsim is up).
    2. In MacPhone: Bluetooth tab → Scan → Connect to the target device →
       wait for the GATT tree → Start Server.
    3. python3 macphone_netsim_bridge.py
    4. In the Android app, scan for "MacPhone Bridge" and connect.

Reads on the Android side are forwarded to the real device on demand; writes are
forwarded through; and every notify/indicate characteristic is auto-subscribed so
the real device's notifications stream into the emulator.
"""

import asyncio
import glob
import json
import os
import pathlib
import struct
import sys

from bumble.transport import open_transport_or_link
from bumble.device import Device, AdvertisingType
from bumble.hci import Address, OwnAddressType
from bumble.att import Attribute
from bumble.gatt import Service, Characteristic, CharacteristicValue
from bumble.core import AdvertisingData, UUID

BRIDGE_HOST = os.environ.get("MACPHONE_BRIDGE_HOST", "127.0.0.1")
BRIDGE_PORT = int(os.environ.get("MACPHONE_BRIDGE_PORT", "8765"))
PERIPHERAL_NAME = "MacPhone Bridge"
PERIPHERAL_ADDRESS = "F0:F1:F2:F3:F4:F5"
READ_TIMEOUT = 5.0
CLIENT_IDLE_TIMEOUT = float(os.environ.get("MACPHONE_CLIENT_IDLE_TIMEOUT", "45"))
PARENT_PID = int(os.environ.get("MACPHONE_PARENT_PID", "0"))


async def stop_when_parent_exits():
    """Prevent stale virtual peripherals when the supervising Mac app is restarted."""
    if PARENT_PID <= 0:
        return
    while True:
        await asyncio.sleep(2)
        try:
            os.kill(PARENT_PID, 0)
        except ProcessLookupError:
            print(f"[bridge] MacPhone parent {PARENT_PID} exited; stopping bridge.")
            os._exit(0)
        except PermissionError:
            return


def resolve_netsim_transport():
    """Return the Bumble transport spec for netsim.

    If the user pinned MACPHONE_NETSIM_TRANSPORT, honour it. Otherwise locate netsim's
    grpc port from its `netsim.ini`. The emulator writes that file into its own TMPDIR,
    which differs depending on whether it was launched from a terminal or from a GUI app
    (launchd gives apps a per-app TMPDIR). We therefore search several candidate dirs and
    pass an explicit host:port so discovery does not depend on a matching TMPDIR.
    """
    pinned = os.environ.get("MACPHONE_NETSIM_TRANSPORT")
    if pinned:
        return pinned

    candidates = []
    if tmpdir := os.environ.get("TMPDIR"):
        candidates.append(pathlib.Path(tmpdir))
    home = pathlib.Path.home()
    candidates.append(home / "Library/Caches/TemporaryItems")
    # Per-app launchd temp dirs: /var/folders/xx/yyy/T/
    candidates.extend(pathlib.Path(p) for p in glob.glob("/var/folders/*/*/T"))
    candidates.append(pathlib.Path("/tmp"))

    for directory in candidates:
        ini = directory / "netsim.ini"
        try:
            if not ini.is_file():
                continue
            for line in ini.read_text().splitlines():
                if line.startswith("grpc.port="):
                    port = line.split("=", 1)[1].strip()
                    print(f"[netsim] using grpc port {port} from {ini}")
                    return f"android-netsim:127.0.0.1:{port}"
        except OSError:
            continue

    print("[netsim] no netsim.ini found; falling back to default android-netsim discovery")
    return "android-netsim"


def properties_from(names):
    p = Characteristic.Properties(0)
    if "read" in names:
        p |= Characteristic.Properties.READ
    if "write" in names:
        p |= Characteristic.Properties.WRITE
    if "writeNR" in names:
        p |= Characteristic.Properties.WRITE_WITHOUT_RESPONSE
    if "notify" in names:
        p |= Characteristic.Properties.NOTIFY
    if "indicate" in names:
        p |= Characteristic.Properties.INDICATE
    return p


def permissions_from(names):
    perms = Attribute.Permissions(0)
    if "read" in names:
        perms |= Attribute.Permissions.READABLE
    if "write" in names or "writeNR" in names:
        perms |= Attribute.Permissions.WRITEABLE
    return perms


def _hex_to_bytes(text):
    """Tolerant hex decode — a malformed payload must not kill the read loop."""
    try:
        return bytes.fromhex(text or "")
    except ValueError:
        print(f"[bridge] ignoring malformed hex payload: {text!r}")
        return b""


def _route_key(service, uuid):
    """Stable routing key. Prefer service+characteristic so the same characteristic UUID
    under two services never collides; fall back to characteristic-only when the Mac side
    omitted the service (older protocol)."""
    char = (uuid or "").lower()
    svc = (service or "").lower()
    return f"{svc}/{char}" if svc else char


class BridgeClient:
    """Async line-delimited JSON client for MacPhone's BLEBridgeServer."""

    def __init__(self):
        self.reader = None
        self.writer = None
        self.gatt = asyncio.get_event_loop().create_future()
        # Advertisement of the real device (name + manufacturer data), forwarded by MacPhone.
        self.advertisement = {}
        # Keyed by both "service/char" and bare "char" so a read resolves regardless of
        # whether the readResult carries a service.
        self._read_waiters = {}   # key -> [futures]
        self.on_value = None      # callback(key, char_uuid, data: bytes)
        self.on_state = None      # callback(state: str)
        self.on_android_activity = None

    async def connect(self):
        self.reader, self.writer = await asyncio.open_connection(BRIDGE_HOST, BRIDGE_PORT)

    def _resolve_read(self, keys, data):
        for key in keys:
            for fut in self._read_waiters.pop(key, []):
                if not fut.done():
                    fut.set_result(data)

    def _fail_pending(self):
        for waiters in self._read_waiters.values():
            for fut in waiters:
                if not fut.done():
                    fut.set_result(b"")
        self._read_waiters.clear()

    async def run(self):
        while True:
            line = await self.reader.readline()
            if not line:
                print("[bridge] connection closed by MacPhone")
                self._fail_pending()
                if self.on_state:
                    self.on_state("closed")
                return
            try:
                msg = json.loads(line.decode("utf-8"))
            except json.JSONDecodeError:
                continue

            kind = msg.get("type")
            if kind == "gatt":
                services = msg.get("services", [])
                self.advertisement = msg.get("advertisement") or {}
                print(f"[bridge] GATT received: {len(services)} services; "
                      f"advertisement: {self.advertisement or 'none'}")
                if not self.gatt.done():
                    self.gatt.set_result(services)
            elif kind in ("readResult", "notification", "value"):
                service = msg.get("service")
                char = (msg.get("characteristic") or "").lower()
                data = _hex_to_bytes(msg.get("value"))
                full = _route_key(service, char)
                # "value" (legacy) and "readResult" satisfy a pending read; a plain
                # "notification" never does, so it can't accidentally answer a read.
                if kind in ("readResult", "value"):
                    self._resolve_read([full, char], data)
                if kind in ("notification", "value") and self.on_value:
                    self.on_value(full, char, data)
            elif kind == "state":
                state = msg.get("value")
                print(f"[bridge] device state: {state}")
                if state == "disconnected":
                    self._fail_pending()
                if self.on_state:
                    self.on_state(state)

    def _send(self, obj):
        self.writer.write((json.dumps(obj) + "\n").encode("utf-8"))

    async def read(self, service, uuid):
        if self.on_android_activity:
            self.on_android_activity()
        print(f"[android -> scooter] READ  {service}/{uuid}")
        fut = asyncio.get_event_loop().create_future()
        self._read_waiters.setdefault(_route_key(service, uuid), []).append(fut)
        self._send({"cmd": "read", "service": service, "characteristic": uuid})
        try:
            return await asyncio.wait_for(fut, timeout=READ_TIMEOUT)
        except asyncio.TimeoutError:
            return b""

    def write(self, service, uuid, data, with_response):
        if self.on_android_activity:
            self.on_android_activity()
        print(f"[android -> scooter] WRITE {service}/{uuid} "
              f"{'with-response' if with_response else 'without-response'}: {data.hex(' ')}")
        self._send({
            "cmd": "write",
            "service": service,
            "characteristic": uuid,
            "value": data.hex(),
            "withResponse": with_response,
        })

    def reset_session(self):
        print("[bridge] requesting fresh real BLE session for the next Android client")
        self._send({"cmd": "resetSession"})

    def subscribe(self, service, uuid, enabled=True):
        self._send({
            "cmd": "subscribe",
            "service": service,
            "characteristic": uuid,
            "enabled": enabled,
        })


def build_advertising(advertisement, services_desc):
    """Reconstruct adv + scan-response packets that mirror the real device's advertisement.

    The recognition key for model-matching apps is the manufacturer-specific data, so it
    goes in the main (always-on) packet together with FLAGS and — budget permitting — the
    local name. Anything that does not fit the 31-byte main packet (name overflow, 128-bit
    service UUIDs) goes in the scan response. Returns (adv, scan_response, advertised_name).
    """
    advertisement = advertisement or {}
    name = advertisement.get("localName") or PERIPHERAL_NAME
    mfg_hex = advertisement.get("manufacturerData")
    mfg = _hex_to_bytes(mfg_hex) if mfg_hex else b""

    def encoded_len(data):  # one AD structure: length + type + payload
        return 2 + len(data)

    main = [(AdvertisingData.FLAGS, bytes([0x06]))]
    used = encoded_len(b"\x06")
    scan = []

    if mfg:
        main.append((AdvertisingData.MANUFACTURER_SPECIFIC_DATA, mfg))
        used += encoded_len(mfg)

    # A name longer than a whole packet (29 data bytes) must be shortened to advertise at all.
    name_bytes = name.encode("utf-8")
    name_type = AdvertisingData.COMPLETE_LOCAL_NAME
    if len(name_bytes) > 29:
        name_bytes = name_bytes[:29]
        name_type = AdvertisingData.SHORTENED_LOCAL_NAME
    scan_used = 0
    if used + encoded_len(name_bytes) <= 31:
        main.append((name_type, name_bytes))
        used += encoded_len(name_bytes)
    else:
        scan.append((name_type, name_bytes))
        scan_used += encoded_len(name_bytes)

    # Service data (e.g. Xiaomi FE95 MiBeacon) is another recognition signal some apps read.
    # 16-bit-UUID service data is compact, so try the main packet first, else the scan resp.
    for uuid, value_hex in (advertisement.get("serviceData") or {}).items():
        uuid16 = _uuid16(uuid)
        if uuid16 is None:
            continue
        payload = struct.pack("<H", uuid16) + _hex_to_bytes(value_hex)
        entry = (AdvertisingData.SERVICE_DATA_16_BIT_UUID, payload)
        if used + encoded_len(payload) <= 31:
            main.append(entry)
            used += encoded_len(payload)
        elif scan_used + encoded_len(payload) <= 31:
            scan.append(entry)
            scan_used += encoded_len(payload)

    # 128-bit service UUIDs are large (16 bytes each); keep them in the scan response,
    # stopping before the 31-byte limit so Bumble doesn't reject an oversized packet.
    for uuid in advertisement.get("serviceUUIDs", []):
        try:
            raw = bytes(UUID(uuid))
        except (ValueError, TypeError):
            continue
        if scan_used + encoded_len(raw) > 31:
            break
        scan.append((AdvertisingData.COMPLETE_LIST_OF_128_BIT_SERVICE_CLASS_UUIDS, raw))
        scan_used += encoded_len(raw)

    return bytes(AdvertisingData(main)), (bytes(AdvertisingData(scan)) if scan else b""), name


def _uuid16(uuid):
    """Return the 16-bit short form of a Bluetooth UUID, or None if it isn't one.

    macOS reports 16-bit UUIDs both as "FE95" and as the full Bluetooth-base
    "0000FE95-0000-1000-8000-00805F9B34FB"; accept either.
    """
    text = (uuid or "").strip().upper().replace("-", "")
    if len(text) == 4:
        return int(text, 16)
    if len(text) == 32 and text.startswith("0000") and text.endswith("00001000800000805F9B34FB"):
        return int(text[4:8], 16)
    return None


def build_services(services_desc, bridge):
    """Translate the JSON GATT description into Bumble services, returning the
    services plus a route-key→Characteristic map for routing notifications."""
    services = []
    char_by_key = {}

    for service_desc in services_desc:
        service_uuid = service_desc["uuid"]
        characteristics = []
        for char_desc in service_desc.get("characteristics", []):
            uuid = char_desc["uuid"]
            # The Mac echoes the owning service in events; prefer the per-characteristic
            # service field but fall back to the enclosing service.
            svc = char_desc.get("service", service_uuid)
            names = char_desc.get("properties", [])

            def make_read(s, u):
                async def _read(_connection):
                    return await bridge.read(s, u)
                return _read

            def make_write(s, u, with_response):
                def _write(_connection, value):
                    bridge.write(s, u, bytes(value), with_response)
                return _write

            characteristic = Characteristic(
                uuid,
                properties_from(names),
                permissions_from(names),
                CharacteristicValue(
                    read=make_read(svc, uuid) if "read" in names else None,
                    write=make_write(svc, uuid, "write" in names)
                    if ("write" in names or "writeNR" in names) else None,
                ),
            )
            characteristics.append(characteristic)
            # Register under the precise key and the bare char UUID so notifications
            # route whether or not the event carries a service.
            char_by_key[_route_key(svc, uuid)] = characteristic
            char_by_key.setdefault(uuid.lower(), characteristic)

        services.append(Service(service_uuid, characteristics))

    return services, char_by_key


async def main():
    asyncio.create_task(stop_when_parent_exits())
    bridge = BridgeClient()
    try:
        await bridge.connect()
    except OSError as error:
        print(f"Could not reach MacPhone bridge at {BRIDGE_HOST}:{BRIDGE_PORT} ({error}).")
        print("In MacPhone: connect to a device, then press 'Start Server'.")
        sys.exit(1)

    asyncio.create_task(bridge.run())
    print("Connected to MacPhone. Waiting for the GATT mirror "
          "(connect to a device in MacPhone)…")
    services_desc = await bridge.gatt

    transport_spec = resolve_netsim_transport()
    async with await open_transport_or_link(transport_spec) as hci:
        device = Device.with_hci(
            PERIPHERAL_NAME,
            Address(PERIPHERAL_ADDRESS),
            hci.source,
            hci.sink,
        )

        services, char_by_key = build_services(services_desc, bridge)
        for service in services:
            device.add_service(service)

        def on_value(key, char_uuid, data):
            characteristic = char_by_key.get(key) or char_by_key.get(char_uuid.lower())
            if characteristic is not None:
                print(f"[scooter -> android] NOTIFY {key}: {data.hex(' ')}")
                asyncio.create_task(device.notify_subscribers(characteristic, value=data))

        bridge.on_value = on_value

        def on_state(state):
            if state in ("disconnected", "closed"):
                print(f"[bridge] real device {state}; notifications paused until it returns.")

        bridge.on_state = on_state

        await device.power_on()

        active_connection = [None]
        last_client_activity = [0.0]

        def mark_client_activity():
            last_client_activity[0] = asyncio.get_running_loop().time()

        bridge.on_android_activity = mark_client_activity

        @device.on("connection")
        def on_connection(connection):
            active_connection[0] = connection
            mark_client_activity()
            print(f"[netsim] Android GATT client connected: {connection.peer_address}")

            @connection.once("disconnection")
            def on_disconnection(reason):
                if active_connection[0] is connection:
                    active_connection[0] = None
                print(f"[netsim] Android GATT client disconnected (reason=0x{reason:02X}); "
                      "advertising will restart.")
                bridge.reset_session()

        async def disconnect_stale_client():
            while True:
                await asyncio.sleep(5)
                connection = active_connection[0]
                if connection is None:
                    continue
                idle = asyncio.get_running_loop().time() - last_client_activity[0]
                if idle < CLIENT_IDLE_TIMEOUT:
                    continue
                print(f"[netsim] Android GATT client idle for {idle:.0f}s; disconnecting it "
                      "so another app can scan/connect.")
                try:
                    await connection.disconnect()
                except Exception as error:
                    print(f"[netsim] stale-client disconnect failed: {error}")

        asyncio.create_task(disconnect_stale_client())

        # Auto-subscribe on the real device for everything that can notify, so the
        # emulator receives the live stream without the app having to ask first.
        for service_desc in services_desc:
            svc = service_desc["uuid"]
            for char_desc in service_desc.get("characteristics", []):
                props = char_desc.get("properties", [])
                if "notify" in props or "indicate" in props:
                    bridge.subscribe(char_desc.get("service", svc), char_desc["uuid"], True)

        advertising_data, scan_response_data, adv_name = build_advertising(
            bridge.advertisement, services_desc
        )
        await device.start_advertising(
            advertising_type=AdvertisingType.UNDIRECTED_CONNECTABLE_SCANNABLE,
            # PUBLIC so apps that reconnect by MAC (e.g. XiaoDash) match the controller's
            # filter-accept-list entry — a RANDOM advertiser silently times out on connect.
            own_address_type=OwnAddressType.PUBLIC,
            auto_restart=True,
            advertising_data=advertising_data,
            scan_response_data=scan_response_data or None,
        )

        total_chars = sum(len(s.get("characteristics", [])) for s in services_desc)
        print(f"Advertising on netsim as '{adv_name}' "
              f"({len(services_desc)} services, {total_chars} characteristics).")
        if bridge.advertisement.get("manufacturerData"):
            print(f"Re-broadcasting the real device's manufacturer data "
                  f"({bridge.advertisement['manufacturerData']}) so model-matching apps recognise it.")
        print("Scan for it in the Android app under test. Ctrl+C to stop.")

        await asyncio.get_event_loop().create_future()  # run forever


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\nStopped.")
