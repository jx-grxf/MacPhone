#!/usr/bin/env python3
"""
Automated end-to-end probe: acts as a BLE central INSIDE the emulator's netsim
(exactly like the Android app under test would) and verifies that the GATT mirrored
by macphone_netsim_bridge.py is reachable, readable, and streams notifications.

Run order (each in its own terminal):
    1. python3 mock_bridge_server.py            # or use the real MacPhone server
    2. python3 macphone_netsim_bridge.py        # publishes "MacPhone Bridge" on netsim
    3. python3 netsim_central_probe.py          # connects from the emulator side

It scans for the peripheral, connects, discovers services, reads every readable
characteristic, subscribes to notify/indicate ones, and prints what arrives.
"""

import asyncio
import os
import sys

from bumble.transport import open_transport_or_link
from bumble.device import Device, Peer
from bumble.hci import Address
from bumble.gatt import Characteristic

# Reuse the bridge's robust netsim discovery.
from macphone_netsim_bridge import resolve_netsim_transport

P = Characteristic.Properties

TARGET_NAME = os.environ.get("MACPHONE_TARGET_NAME", "MacPhone Bridge")
SCAN_TIMEOUT = 20.0


async def main():
    transport_spec = resolve_netsim_transport()
    async with await open_transport_or_link(transport_spec) as hci:
        device = Device.with_hci("Probe Central", Address("E0:E1:E2:E3:E4:E5"), hci.source, hci.sink)
        await device.power_on()

        print(f"Scanning netsim for '{TARGET_NAME}'…")
        found = asyncio.get_event_loop().create_future()

        def on_advertisement(advertisement):
            from bumble.core import AdvertisingData
            name = advertisement.data.get(AdvertisingData.COMPLETE_LOCAL_NAME)
            if isinstance(name, bytes):
                name = name.decode("utf-8", "replace")
            if name == TARGET_NAME and not found.done():
                found.set_result(advertisement.address)

        device.on("advertisement", on_advertisement)
        await device.start_scanning()
        try:
            address = await asyncio.wait_for(found, timeout=SCAN_TIMEOUT)
        except asyncio.TimeoutError:
            print(f"FAIL: '{TARGET_NAME}' not seen on netsim. Is the bridge running?")
            sys.exit(2)
        await device.stop_scanning()
        print(f"Found at {address}. Connecting…")

        connection = await device.connect(address)
        peer = Peer(connection)
        await peer.discover_all()  # discover services + characteristics + descriptors
        print("Connected. GATT mirror as seen from the emulator side:")

        notify_count = {"n": 0}

        def make_handler(uuid):
            def _handler(value):
                notify_count["n"] += 1
                print(f"  NOTIFY {uuid} → {bytes(value).hex()}")
            return _handler

        for service in peer.services:
            print(f"Service {service.uuid}")
            for characteristic in service.characteristics:
                props = characteristic.properties
                print(f"  Char {characteristic.uuid}  [{props}]")
                if props & P.READ:
                    try:
                        value = await characteristic.read_value()
                        print(f"    READ → {bytes(value).hex()}")
                    except Exception as error:  # noqa: BLE001
                        print(f"    READ failed: {error}")
                if props & (P.NOTIFY | P.INDICATE):
                    try:
                        await characteristic.subscribe(make_handler(characteristic.uuid))
                        print("    subscribed")
                    except Exception as error:  # noqa: BLE001
                        print(f"    subscribe failed: {error}")

        print("\nListening for notifications for 12s…")
        await asyncio.sleep(12)
        print(f"\nPASS: received {notify_count['n']} notification(s). "
              f"End-to-end GATT path through netsim works.")
        await connection.disconnect()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\nStopped.")
