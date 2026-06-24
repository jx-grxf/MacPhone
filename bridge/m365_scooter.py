#!/usr/bin/env python3
"""
Emulated Xiaomi M365 scooter on the Android emulator's netsim controller.

Standalone test fixture — it does NOT involve the MacPhone app. It advertises itself like
a real M365 (name ``MIScooter…`` + Xiaomi service ``0xFE95``), exposes the Nordic UART
Service, and answers the unencrypted M365 packet protocol so apps such as XiaoDash can
discover it, connect, and read live telemetry.

    THIS SCRIPT  ──Bumble peripheral──▶  android-netsim ──▶  XiaoDash (in the emulator)

Run order:
    1. Start the Android emulator (so netsim is up).
    2. python3 m365_scooter.py            (or ./run_scooter.sh)
    3. In XiaoDash, scan & connect to "MIScooter…".

Wire format (app → 6e400002 write, scooter → 6e400003 notify):

    55 AA LEN ADDR CMD [PAYLOAD…] CK0 CK1

- ``55 AA`` header (excluded from LEN and checksum)
- ``LEN``  = 1 (CMD) + len(PAYLOAD)         (ADDR is not counted)
- ``ADDR`` = 0x20 ESC/controller, 0x22 BMS, 0x21 BLE
- ``CMD``  = 0x01 read
- checksum = (sum of every byte after ``55 AA`` except the checksum) XOR 0xFFFF, little-endian
"""

import asyncio
import os
import struct
import sys

from bumble.transport import open_transport_or_link
from bumble.device import Device, AdvertisingType
from bumble.hci import Address, OwnAddressType
from bumble.att import Attribute
from bumble.gatt import Service, Characteristic, CharacteristicValue
from bumble.core import AdvertisingData, UUID

# Reuse the emulator/netsim discovery from the bridge so both agree on the transport.
from macphone_netsim_bridge import resolve_netsim_transport

NUS_SERVICE = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
NUS_RX_WRITE = "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"   # app writes commands here
NUS_TX_NOTIFY = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"  # scooter notifies replies here
XIAOMI_SERVICE_16 = 0xFE95                              # advertised, like a real M365

# Scooter apps (e.g. XiaoDash) identify the model from manufacturer-specific data:
# company id 0x424E, then byte[0] = device type. 0x20 = the original M365 ("ESCOOTER"),
# which speaks the unencrypted protocol this script emulates. byte[1] is a sub/version.
MFG_COMPANY_ID = 0x424E
DEVICE_TYPE = int(os.environ.get("M365_TYPE", "0x20"), 0)
DEVICE_SUBTYPE = int(os.environ.get("M365_SUBTYPE", "0"), 0)

DEVICE_NAME = os.environ.get("M365_NAME", "MIScooter1234")
DEVICE_ADDRESS = os.environ.get("M365_ADDR", "F0:F1:F2:F3:F4:F6")


def checksum(body: bytes) -> bytes:
    cs = (sum(body) ^ 0xFFFF) & 0xFFFF
    return bytes([cs & 0xFF, (cs >> 8) & 0xFF])


def frame(addr: int, cmd: int, payload: bytes) -> bytes:
    body = bytes([(1 + len(payload)) & 0xFF, addr, cmd]) + bytes(payload)
    return b"\x55\xAA" + body + checksum(body)


def reply_addr(request_addr: int) -> int:
    return {0x20: 0x23, 0x22: 0x25}.get(request_addr, request_addr)


ESC = 0x20
BMS = 0x22

# Battery temperatures are reported as a single byte with a +20 °C bias (raw 0 → −20 °C).
TEMP_BIAS = 20


class RegisterFile:
    """A flat M365 register space, addressed exactly like the wire protocol.

    A read names a start register and a length *in bytes*; the device answers with
    the contiguous block beginning there. Each 16-bit register therefore occupies two
    bytes, so register ``r`` lives at byte offset ``2 * r``. Modelling it as one byte
    array (instead of a per-register lookup) is what makes XiaoDash's block reads —
    e.g. BMS ``0x30`` for 24 bytes, ESC ``0xB0`` for 28 — line up field-for-field.
    """

    def __init__(self, size: int = 0x200):
        self.mem = bytearray(size)

    def u16(self, register: int, value: int):
        struct.pack_into("<H", self.mem, register * 2, value & 0xFFFF)

    def i16(self, register: int, value: int):
        struct.pack_into("<h", self.mem, register * 2, value)

    def u32(self, register: int, value: int):
        struct.pack_into("<I", self.mem, register * 2, value & 0xFFFFFFFF)

    def blob(self, register: int, data: bytes):
        self.mem[register * 2:register * 2 + len(data)] = data

    def read(self, register: int, length: int) -> bytes:
        start = register * 2
        return bytes(self.mem[start:start + length]).ljust(length, b"\x00")


class Scooter:
    """Live-ish telemetry for a half-charged, idle M365, served as register blocks."""

    def __init__(self):
        self.battery_percent = 86
        self.voltage_cv = 4020        # 40.20 V  (units of 10 mV)
        self.current_ca = 0           # idle     (units of 10 mA, signed)
        self.remaining_mah = 5200
        self.cell_mv = 4020           # 10S pack ≈ 4.02 V/cell at this charge
        self.trip_m = 1234            # 1.234 km this ride
        self.total_m = 152_380        # 152.38 km lifetime
        self.frame_temp_cx10 = 235    # 23.5 °C controller
        self.bms_temp_c = 23          # 23 °C pack
        self.speed_kmh_x100 = 0       # idle
        self.firmware = 0x0143
        self.serial = b"16273/00001234"

        self.esc = RegisterFile()
        self.bms = RegisterFile()
        self._populate()

    def _populate(self):
        # --- ESC / controller (addr 0x20) ---
        self.esc.blob(0x10, self.serial)            # serial number
        self.esc.u16(0x1A, self.firmware)           # ESC firmware version
        self.esc.u16(0x25, self.trip_m)             # trip distance (m)
        self.esc.u32(0x29, self.total_m)            # lifetime odometer (m)
        # Realtime status block at 0xB0 (battery %, speed, frame temp).
        self.esc.u16(0xB0, 0)                       # error code
        self.esc.u16(0xB1, 0)                       # warning code
        self.esc.u16(0xB4, self.battery_percent)    # battery %
        self.esc.i16(0xB5, self.speed_kmh_x100)     # current speed (km/h ×100)
        self.esc.u16(0xB7, self.total_m & 0xFFFF)   # odometer low word
        self.esc.u16(0xB8, self.total_m >> 16)      # odometer high word
        self.esc.u16(0xB9, self.trip_m)             # trip distance (m)
        self.esc.u16(0xBB, self.frame_temp_cx10)    # frame temperature (×10 °C)
        self.esc.u16(0xBE, self.frame_temp_cx10)    # frame temperature (alt block)

        # --- BMS / battery (addr 0x22) ---
        self.bms.blob(0x10, self.serial)            # pack serial
        self.bms.u16(0x18, 7800)                    # design capacity (mAh)
        self.bms.u16(0x19, 7500)                    # full capacity (mAh)
        self.bms.u16(0x1B, 12)                      # charge cycles
        self.bms.u16(0x31, self.remaining_mah)      # remaining capacity (mAh)
        self.bms.u16(0x32, self.battery_percent)    # remaining %
        self.bms.i16(0x33, self.current_ca)         # current (×10 mA, signed)
        self.bms.u16(0x34, self.voltage_cv)         # pack voltage (×10 mV)
        self.bms.u16(0x35, (self.bms_temp_c + TEMP_BIAS) |
                           ((self.bms_temp_c + TEMP_BIAS) << 8))  # temp1 | temp2
        for cell in range(10):                      # 10 cell voltages (mV)
            self.bms.u16(0x40 + cell, self.cell_mv)

    def register_bytes(self, addr: int, register: int, length: int) -> bytes:
        bank = self.bms if addr == BMS else self.esc
        return bank.read(register, length)

    def reply(self, data: bytes):
        if len(data) < 7 or data[0] != 0x55 or data[1] != 0xAA:
            return []
        addr, cmd = data[3], data[4]
        if cmd != 0x01:
            return []
        register, requested = data[5], data[6]
        length = max(1, min(requested, 64))
        # Real M365 firmware answers a read with just the register block — no echoed
        # register byte — so the requester finds each field at (reg − start) × 2.
        return [frame(reply_addr(addr), 0x01, self.register_bytes(addr, register, length))]


async def main():
    scooter = Scooter()
    transport_spec = resolve_netsim_transport()

    async with await open_transport_or_link(transport_spec) as hci:
        # Advertise with a PUBLIC address, like a real M365. Apps that reconnect by MAC
        # string (e.g. XiaoDash via getRemoteDevice) default the peer to a PUBLIC address and
        # put it on the controller's filter-accept-list. A RANDOM advertiser then never
        # matches that entry, so the initiator silently drops every connection attempt.
        device = Device.with_hci(
            DEVICE_NAME,
            Address(DEVICE_ADDRESS, Address.PUBLIC_DEVICE_ADDRESS),
            hci.source,
            hci.sink,
        )

        tx_char = Characteristic(
            NUS_TX_NOTIFY,
            Characteristic.Properties.NOTIFY,
            Attribute.Permissions.READABLE,
        )

        def on_write(_connection, value):
            for reply in scooter.reply(bytes(value)):
                print(f"[m365] {bytes(value).hex()} → {reply.hex()}")
                asyncio.create_task(device.notify_subscribers(tx_char, value=reply))

        rx_char = Characteristic(
            NUS_RX_WRITE,
            Characteristic.Properties.WRITE | Characteristic.Properties.WRITE_WITHOUT_RESPONSE,
            Attribute.Permissions.WRITEABLE,
            CharacteristicValue(write=on_write),
        )

        device.add_service(Service(NUS_SERVICE, [tx_char, rx_char]))
        await device.power_on()

        # XiaoDash scans unfiltered and identifies the model from manufacturer-specific
        # data: company id 0x424E, byte[0] = device type (0x20 = original M365), byte[1] =
        # sub/version. Without it the device shows in nRF Connect but XiaoDash ignores it.
        # The main packet carries name + manufacturer data so XiaoDash matches on first sight;
        # the Nordic UART UUID + Xiaomi 0xFE95 go in the scan response (31-byte adv limit).
        mfg_data = struct.pack("<H", MFG_COMPANY_ID) + bytes([DEVICE_TYPE, DEVICE_SUBTYPE])
        advertising_data = bytes(AdvertisingData([
            (AdvertisingData.FLAGS, bytes([0x06])),
            (AdvertisingData.COMPLETE_LOCAL_NAME, DEVICE_NAME.encode("utf-8")),
            (AdvertisingData.MANUFACTURER_SPECIFIC_DATA, mfg_data),
        ]))
        scan_response_data = bytes(AdvertisingData([
            (AdvertisingData.COMPLETE_LIST_OF_128_BIT_SERVICE_CLASS_UUIDS, bytes(UUID(NUS_SERVICE))),
            (AdvertisingData.INCOMPLETE_LIST_OF_16_BIT_SERVICE_CLASS_UUIDS,
             struct.pack("<H", XIAOMI_SERVICE_16)),
        ]))
        await device.start_advertising(
            advertising_type=AdvertisingType.UNDIRECTED_CONNECTABLE_SCANNABLE,
            own_address_type=OwnAddressType.PUBLIC,  # advertise PUBLIC; see Address() note above
            auto_restart=True,
            advertising_data=advertising_data,
            scan_response_data=scan_response_data,
        )

        print(f"Advertising emulated M365 as '{DEVICE_NAME}' on netsim "
              f"(Nordic UART + Xiaomi 0xFE95). Scan for it in XiaoDash. Ctrl+C to stop.")
        await asyncio.get_event_loop().create_future()  # run forever


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\nStopped.")
