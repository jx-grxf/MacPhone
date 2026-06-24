#!/usr/bin/env python3
"""Mock of MacPhone's BLEBridgeServer for testing the netsim bridge without a real
BLE device. Sends one fake GATT (battery + a custom notify/write service) and then
emits a battery notification every few seconds."""
import asyncio
import json
import os

PORT = int(os.environ.get("MACPHONE_BRIDGE_PORT", "8799"))

GATT = {
    "type": "gatt",
    "services": [
        {"uuid": "180F", "characteristics": [
            {"uuid": "2A19", "properties": ["read", "notify"]},
        ]},
        {"uuid": "0000fe95-0000-1000-8000-00805f9b34fb", "characteristics": [
            {"uuid": "0000fe01-0000-1000-8000-00805f9b34fb", "properties": ["write", "notify"]},
            {"uuid": "0000fe02-0000-1000-8000-00805f9b34fb", "properties": ["read"]},
        ]},
    ],
}


async def handle(reader, writer):
    print("[mock] client connected")
    writer.write((json.dumps({"type": "state", "value": "connected"}) + "\n").encode())
    writer.write((json.dumps(GATT) + "\n").encode())
    await writer.drain()

    async def reader_task():
        while True:
            line = await reader.readline()
            if not line:
                return
            print("[mock] cmd:", line.decode().strip())

    asyncio.create_task(reader_task())
    level = 88
    while True:
        await asyncio.sleep(4)
        level = max(1, level - 1)
        writer.write((json.dumps({"type": "value", "characteristic": "2A19",
                                  "value": f"{level:02x}"}) + "\n").encode())
        await writer.drain()
        print(f"[mock] pushed battery {level}%")


async def main():
    server = await asyncio.start_server(handle, "127.0.0.1", PORT)
    print(f"[mock] listening on 127.0.0.1:{PORT}")
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    asyncio.run(main())
