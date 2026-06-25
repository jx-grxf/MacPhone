#!/usr/bin/env python3
"""
Emulated Segway-Ninebot scooter on the Android emulator's netsim controller.

Standalone test fixture for the *encrypted* Ninebot transport, parameterized by model via the
NB_MODEL env var (see MODELS below): Max G2, Max G3, Max G30, and the F line (F20/F25/F30/F40,
F2/F2 Pro). It advertises like the chosen model (company 0x424E, a device-type byte), runs the
NinebotCrypto session handshake, answers telemetry reads and persists/acks writes — so E-Tune
(or any client speaking the protocol) can pair, read data and exercise tuning without real
hardware. Launch via run_ninebot.sh [model].

    THIS SCRIPT  ──Bumble peripheral──▶  android-netsim ──▶  E-Tune (in the emulator)

There is no physical power button, so the scooter auto-confirms the pairing (it sends the
`5C 01` button-press acknowledgement itself) right after the app's `5C` arrives.

NinebotCrypto is the open scooterhacking/NinebotCrypto algorithm (AGPL-3.0), ported to
Python for this test fixture only.
"""

import asyncio
import hashlib
import os
import struct

from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.backends import default_backend

from bumble.transport import open_transport_or_link
from bumble.device import Device, AdvertisingType
from bumble.hci import Address, OwnAddressType
from bumble.att import Attribute
from bumble.gatt import Service, Characteristic, CharacteristicValue
from bumble.core import AdvertisingData, UUID

from macphone_netsim_bridge import resolve_netsim_transport

NUS_SERVICE = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
NUS_RX_WRITE = "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"
NUS_TX_NOTIFY = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"

MFG_COMPANY_ID = 0x424E

# Catalog of Ninebot models to emulate. All use the encrypted Ninebot transport (the path E-Tune's
# NinebotProtocol speaks), so the same fixture covers G2, G3, the G30/Max and the whole F line.
# `type` is the manufacturer-data device-type byte (any value != 0x20 routes to the Ninebot path in
# E-Tune; values are plausible test markers). `name` seeds the NinebotCrypto key on both sides.
# Exactly the Segway-Ninebot models E-Tune must support (the Xiaomi M365 family has its own
# plaintext path / Swift fixture). `type` is the manufacturer device-type byte (any value != 0x20
# routes to E-Tune's encrypted Ninebot path; values here are plausible test markers). `name` seeds
# the NinebotCrypto key on both sides.
# Name embeds the model code so E-Tune's BrandDetector can label it; the name also seeds the
# NinebotCrypto key (both sides use MODEL["name"], so it can be any matching string).
MODELS = {
    "g2":     {"display": "Ninebot Max G2",   "name": "G2-2312345601",  "type": 0x83, "serial": "N4GUB2341C0543", "battery": 73, "total_m": 152380, "trip_m": 1234},
    "g3":     {"display": "Ninebot Max G3",   "name": "G3-3412345602",  "type": 0x90, "serial": "N7GUB3451C0028", "battery": 88, "total_m": 4200,   "trip_m": 300},
    "g30":    {"display": "Ninebot Max G30",  "name": "G30-912345603",  "type": 0x70, "serial": "N3GUB1931C0777", "battery": 64, "total_m": 853200, "trip_m": 5120},
    "e22":    {"display": "Ninebot E22",      "name": "E22-12345604",   "type": 0x50, "serial": "N2EUE2231C0040", "battery": 60, "total_m": 33000,  "trip_m": 700},
    "e25":    {"display": "Ninebot E25",      "name": "E25-12345605",   "type": 0x51, "serial": "N2EUE2531C0041", "battery": 75, "total_m": 41000,  "trip_m": 950},
    "e45":    {"display": "Ninebot E45",      "name": "E45-12345606",   "type": 0x52, "serial": "N2EUE4531C0042", "battery": 82, "total_m": 52000,  "trip_m": 1300},
    "es1":    {"display": "Ninebot ES1",      "name": "ES1-12345607",   "type": 0x40, "serial": "N1EUES131C0010", "battery": 48, "total_m": 9000,   "trip_m": 120},
    "es2":    {"display": "Ninebot ES2",      "name": "ES2-12345608",   "type": 0x41, "serial": "N1EUES231C0011", "battery": 66, "total_m": 15000,  "trip_m": 340},
    "es4":    {"display": "Ninebot ES4",      "name": "ES4-12345609",   "type": 0x42, "serial": "N1EUES431C0012", "battery": 91, "total_m": 23000,  "trip_m": 510},
    "f65":    {"display": "Ninebot F65",      "name": "F65-12345610",   "type": 0x66, "serial": "N5FUF6531C0065", "battery": 70, "total_m": 28000,  "trip_m": 600},
    "f2":     {"display": "Ninebot F2",       "name": "F2-12345611",    "type": 0x64, "serial": "N8FUF2A1C00014", "battery": 80, "total_m": 3000,   "trip_m": 90},
    "f2plus": {"display": "Ninebot F2 Plus",  "name": "F2PLUS-345612",  "type": 0x68, "serial": "N8FUF2L1C00016", "battery": 84, "total_m": 6400,   "trip_m": 210},
    "f2pro":  {"display": "Ninebot F2 Pro",   "name": "F2PRO-2345613",  "type": 0x65, "serial": "N8FUF2P1C00015", "battery": 71, "total_m": 17000,  "trip_m": 420},
    "zt3pro": {"display": "Ninebot ZT3 Pro",  "name": "ZT3PRO-345614",  "type": 0x95, "serial": "NZT3P341C00099", "battery": 95, "total_m": 1200,   "trip_m": 45},
}

MODEL_KEY = os.environ.get("NB_MODEL", "g2").lower()
MODEL = MODELS.get(MODEL_KEY, MODELS["g2"])

DEVICE_TYPE = int(os.environ.get("NB_TYPE", "0"), 0) or MODEL["type"]
DEVICE_SUBTYPE = int(os.environ.get("NB_SUBTYPE", "0"), 0)
DEVICE_NAME = os.environ.get("NB_NAME", MODEL["name"])         # both sides derive the key from this
DEVICE_ADDRESS = os.environ.get("NB_ADDR", "F0:F1:F2:F3:F4:F7")
SERIAL = os.environ.get("NB_SERIAL", MODEL["serial"]).encode("ascii")[:14].ljust(14, b"\x00")

DATA_BASIC = bytes([0x97, 0xCF, 0xB8, 0x02, 0x84, 0x41, 0x43, 0xDE,
                    0x56, 0x00, 0x2B, 0x3B, 0x34, 0x78, 0x0A, 0x5D])
GATT_CHUNK = 20
ENCRYPTED_OVERHEAD = 13


def aes_ecb(block16: bytes, key16: bytes) -> bytes:
    enc = Cipher(algorithms.AES(bytes(key16)), modes.ECB(), backend=default_backend()).encryptor()
    return enc.update(bytes(block16)) + enc.finalize()


def xor16(a: bytes, b: bytes) -> bytes:
    return bytes((b[i] ^ a[i]) & 0xFF for i in range(len(a)))


class NinebotCrypto:
    """Port of scooterhacking/NinebotCrypto (AGPL-3.0). Symmetric: a peer encrypts its TX and
    decrypts its RX with the same instance; TX/RX counters are independent."""

    def __init__(self, name: str):
        self.name = name.encode("utf-8") if isinstance(name, str) else bytes(name)
        self.random_ble = bytearray(16)
        self.random_app = bytearray(16)
        self.sha_key = bytearray(16)
        self.msg_it = 0
        self.reset()

    def reset(self):
        self.random_ble = bytearray(16)
        self.random_app = bytearray(16)
        self.msg_it = 0
        self.calc_sha1_key(self.name, DATA_BASIC)

    def calc_sha1_key(self, d1: bytes, d2: bytes):
        buf = bytearray(32)
        buf[0:min(16, len(d1))] = d1[:16]
        buf[16:16 + min(16, len(d2))] = d2[:16]
        self.sha_key = bytearray(hashlib.sha1(bytes(buf)).digest()[:16])

    def _crypto_first(self, data: bytes) -> bytes:
        out = bytearray(len(data))
        plen, idx = len(data), 0
        while plen > 0:
            tmp = min(16, plen)
            x1 = bytearray(16)
            x1[0:tmp] = data[idx:idx + tmp]
            x2 = aes_ecb(DATA_BASIC, self.sha_key)
            out[idx:idx + tmp] = xor16(x1, x2)[0:tmp]
            plen -= tmp
            idx += tmp
        return bytes(out)

    def _crypto_next(self, data: bytes, msg_it: int) -> bytes:
        out = bytearray(len(data))
        aed = bytearray(16)
        aed[0] = 1
        aed[1] = (msg_it >> 24) & 0xFF
        aed[2] = (msg_it >> 16) & 0xFF
        aed[3] = (msg_it >> 8) & 0xFF
        aed[4] = msg_it & 0xFF
        aed[5:13] = self.random_ble[0:8]
        aed[15] = 0
        plen, idx = len(data), 0
        while plen > 0:
            aed[15] = (aed[15] + 1) & 0xFF
            tmp = min(16, plen)
            x1 = bytearray(16)
            x1[0:tmp] = data[idx:idx + tmp]
            x2 = aes_ecb(aed, self.sha_key)
            out[idx:idx + tmp] = xor16(x1, x2)[0:tmp]
            plen -= tmp
            idx += tmp
        return bytes(out)

    def _crc_first(self, data: bytes) -> bytes:
        crc = (~sum(data)) & 0xFFFFFFFF
        return bytes([crc & 0xFF, (crc >> 8) & 0xFF])

    def _crc_next(self, data: bytes, msg_it: int) -> bytes:
        aed = bytearray(16)
        plen, idx = len(data) - 3, 3
        aed[0] = 89
        aed[1] = (msg_it >> 24) & 0xFF
        aed[2] = (msg_it >> 16) & 0xFF
        aed[3] = (msg_it >> 8) & 0xFF
        aed[4] = msg_it & 0xFF
        aed[5:13] = self.random_ble[0:8]
        aed[15] = plen & 0xFF
        x2 = bytearray(aes_ecb(aed, self.sha_key))
        x1 = bytearray(16)
        x1[0:3] = data[0:3]
        x2 = bytearray(aes_ecb(xor16(x1, x2), self.sha_key))
        while plen > 0:
            tmp = min(16, plen)
            x1 = bytearray(16)
            x1[0:tmp] = data[idx:idx + tmp]
            x2 = bytearray(aes_ecb(xor16(x1, x2), self.sha_key))
            plen -= tmp
            idx += tmp
        aed[0] = 1
        aed[15] = 0
        ak = aes_ecb(aed, self.sha_key)
        x1 = bytearray(16)
        x1[0:4] = ak[0:4]
        return bytes(xor16(x1, x2))

    def encrypt(self, data: bytes) -> bytes:
        data = bytes(data)
        out = bytearray(152)
        out[0:3] = data[0:3]
        plen = len(data) - 3
        payload = data[3:]
        if self.msg_it == 0:
            crc = self._crc_first(payload)
            payload = self._crypto_first(payload)
            out[3:3 + plen] = payload
            out[plen + 3] = 0
            out[plen + 4] = 0
            out[plen + 5] = crc[0]
            out[plen + 6] = crc[1]
            out[plen + 7] = 0
            out[plen + 8] = 0
            out = out[0:plen + 9]
            self.msg_it += 1
        else:
            self.msg_it += 1
            crc = self._crc_next(data, self.msg_it)
            payload = self._crypto_next(payload, self.msg_it)
            out[3:3 + plen] = payload
            out[plen + 3] = crc[0]
            out[plen + 4] = crc[1]
            out[plen + 5] = crc[2]
            out[plen + 6] = crc[3]
            out[plen + 7] = (self.msg_it >> 8) & 0xFF
            out[plen + 8] = self.msg_it & 0xFF
            out = out[0:plen + 9]
        return bytes(out)

    def decrypt(self, data: bytes) -> bytes:
        data = bytes(data)
        dec = bytearray(len(data) - 6)
        dec[0:3] = data[0:3]
        new_msg_it = (self.msg_it & 0xFFFF0000) + (((data[-2] << 8) & 0xFFFF) + data[-1])
        plen = len(data) - 9
        payload = data[3:3 + plen]
        if new_msg_it == 0:
            payload = self._crypto_first(payload)
        else:
            payload = self._crypto_next(payload, new_msg_it)
            self.msg_it = new_msg_it if new_msg_it > self.msg_it else self.msg_it + 1
        dec[3:3 + len(payload)] = payload
        return bytes(dec)


# --- Register banks the fake Max G2 exposes ---
# A faithful, self-consistent G2: reads return the stored register, writes persist into the bank and
# are acked, so the full E-Tune Ninebot flow (telemetry + experimental fun/tuning writes) round-trips
# — a later read reflects what was written. Register numbers match E-Tune's NinebotProtocol.
ESC, BMS, PHONE = 0x20, 0x22, 0x3E
BANK_SIZE = 0x400


def _build_banks():
    esc = bytearray(BANK_SIZE)
    bms = bytearray(BANK_SIZE)

    def u16(mem, reg, val):
        mem[reg * 2] = val & 0xFF
        mem[reg * 2 + 1] = (val >> 8) & 0xFF

    def u32(mem, reg, val):
        for i in range(4):
            mem[reg * 2 + i] = (val >> (8 * i)) & 0xFF

    def blob(mem, reg, data):
        for i, b in enumerate(data):
            if reg * 2 + i < len(mem):
                mem[reg * 2 + i] = b

    # ESC telemetry / config (seeded from the selected model)
    u16(esc, 0x26, 0)                    # speed (km/h x10) — idle
    u16(esc, 0xB5, MODEL["battery"])     # battery %
    u32(esc, 0xB7, MODEL["total_m"])     # total (m)
    u32(esc, 0xB9, MODEL["trip_m"])      # trip (m)
    blob(esc, 0x10, SERIAL)      # serial (14 ASCII)
    u16(esc, 0x1A, 0x0140)       # firmware (BCD-ish) -> shown as 1.4.0
    u16(esc, 0x70, 0)            # headlight (0=off 1=on)
    u16(esc, 0x71, 0)            # blinker (0=off 1=left 2=right)
    u16(esc, 0x7A, 0)            # beep / horn trigger
    u16(esc, 0x7B, 1)            # KERS / regen level (0/1/2)
    u16(esc, 0x75, 1)            # drive mode (0=eco 1=drive 2=sport)
    u16(esc, 0x7C, 0)            # cruise control (0/1)
    u16(esc, 0x10 + 0, SERIAL[0])  # (no-op safety)
    esc[0x90 * 2] = 0            # lock state (0=unlocked 1=locked) at reg 0x90
    # ESC 0xB0 status block (16 bytes): speed, battery, temp, error — a realistic multi-field read.
    status = bytearray(16)
    status[0:2] = struct.pack("<H", 0)                  # speed x10
    status[2:4] = struct.pack("<H", MODEL["battery"])   # battery %
    status[4:6] = struct.pack("<H", 235)                # temperature 0.1 C
    status[6:8] = struct.pack("<H", 0)                  # error / alarm
    blob(esc, 0xB0, status)

    # BMS
    u16(bms, 0x34, 4180)                 # pack voltage x100 -> 41.80 V
    u16(bms, 0x33, 150)                  # current x100 (signed) -> 1.50 A
    u16(bms, 0x32, MODEL["battery"])     # battery %
    for cell in range(10):
        u16(bms, 0x40 + cell, 4180)
    return esc, bms


WRITE_NAMES = {
    (ESC, 0x70): "HEADLIGHT", (ESC, 0x71): "BLINKER", (ESC, 0x7A): "BEEP/HORN",
    (ESC, 0x7B): "KERS", (ESC, 0x75): "DRIVE MODE", (ESC, 0x7C): "CRUISE",
    (ESC, 0x90): "LOCK", (ESC, 0x1F): "SERIAL/REGION",
}


class FakeMaxG2:
    def __init__(self, send_plain):
        self.crypto = NinebotCrypto(DEVICE_NAME)
        self.send_plain = send_plain          # async callback(plaintext_frame)
        self.rx = bytearray()
        self.ready = False
        self.esc, self.bms = _build_banks()

    def reset(self):
        """A fresh client restarts the handshake from msgIt 0 with the name-derived key."""
        self.crypto.reset()
        self.rx = bytearray()
        self.ready = False
        self.esc, self.bms = _build_banks()

    def _bank(self, addr):
        return self.bms if addr == BMS else self.esc

    def on_chunk(self, data: bytes):
        self.rx += data
        while True:
            start = self.rx.find(b"\x5A\xA5")
            if start < 0:
                self.rx = self.rx[-1:]
                return
            if start > 0:
                del self.rx[:start]
            if len(self.rx) < 3:
                return
            total = (self.rx[2] & 0xFF) + ENCRYPTED_OVERHEAD
            if len(self.rx) < total:
                return
            frame = bytes(self.rx[:total])
            del self.rx[:total]
            asyncio.create_task(self._handle(frame))

    async def _handle(self, enc: bytes):
        try:
            p = self.crypto.decrypt(enc)
        except Exception as error:
            print(f"[nb] decrypt failed: {error}")
            return
        if len(p) < 6:
            return
        src, dst, cmd = p[3], p[4], p[5]
        arg = p[6] if len(p) > 6 else 0
        print(f"[nb] rx plain {p.hex(' ')}")

        if cmd == 0x5B:                                   # identity request → reply with random+serial
            random_ble = os.urandom(16)
            self.crypto.random_ble = bytearray(random_ble)
            reply = b"\x5A\xA5\x1E\x21\x3E\x5B\x00" + random_ble + SERIAL
            await self.send_plain(reply)
            self.crypto.calc_sha1_key(self.crypto.name, self.crypto.random_ble)  # re-derive after 5B
            print("[nb] sent 5B identity (random + serial); key re-derived")
        elif cmd == 0x5C:                                 # app key half → auto-confirm the button press
            if len(p) >= 23:
                self.crypto.random_app = bytearray(p[7:23])
            await self.send_plain(b"\x5A\xA5\x00\x21\x3E\x5C\x01")
            self.crypto.calc_sha1_key(self.crypto.random_app, self.crypto.random_ble)  # finalise
            print("[nb] auto-pressed power button → sent 5C 01; session key finalised")
        elif cmd == 0x5D:                                 # app confirms → authenticated
            await self.send_plain(b"\x5A\xA5\x00\x21\x3E\x5D\x01")
            self.ready = True
            print("[nb] sent 5D 01 → AUTHENTICATED")
        elif cmd == 0x01:                                 # telemetry read
            target, reg, length = dst, arg, (p[7] if len(p) > 7 else 2)
            length = max(1, min(length, 64))
            bank = self._bank(target)
            start = reg * 2
            payload = bytes(bank[start:start + length]).ljust(length, b"\x00")
            reply = bytes([0x5A, 0xA5, len(payload), target, PHONE, 0x01, reg]) + payload
            await self.send_plain(reply)
            print(f"[nb] read {target:#04x}/{reg:#04x} → {payload.hex(' ')}")
        elif cmd == 0x03:                                 # write (tuning / fun command) — persist + ack
            name = WRITE_NAMES.get((dst, arg), "WRITE")
            value = p[7:]
            bank = self._bank(dst)
            start = arg * 2
            for i, b in enumerate(value):
                if start + i < len(bank):
                    bank[start + i] = b
            print(f"[nb] *** {name} write: reg {arg:#04x} = {value.hex(' ')} (persisted) ***")
            await self.send_plain(bytes([0x5A, 0xA5, 0x00, dst, PHONE, 0x03, arg]))


async def main():
    transport_spec = resolve_netsim_transport()
    async with await open_transport_or_link(transport_spec) as hci:
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

        async def send_plain(plaintext: bytes):
            enc = scooter.crypto.encrypt(plaintext)
            for i in range(0, len(enc), GATT_CHUNK):
                await device.notify_subscribers(tx_char, value=enc[i:i + GATT_CHUNK])

        scooter = FakeMaxG2(send_plain)

        rx_char = Characteristic(
            NUS_RX_WRITE,
            Characteristic.Properties.WRITE | Characteristic.Properties.WRITE_WITHOUT_RESPONSE,
            Attribute.Permissions.WRITEABLE,
            CharacteristicValue(write=lambda _c, v: scooter.on_chunk(bytes(v))),
        )

        device.add_service(Service(NUS_SERVICE, [tx_char, rx_char]))

        @device.on("connection")
        def _on_connection(connection):
            scooter.reset()
            print(f"[nb] client connected ({connection.peer_address}) — handshake reset")

        await device.power_on()

        mfg = struct.pack("<H", MFG_COMPANY_ID) + bytes([DEVICE_TYPE, DEVICE_SUBTYPE])
        adv = bytes(AdvertisingData([
            (AdvertisingData.FLAGS, bytes([0x06])),
            (AdvertisingData.COMPLETE_LOCAL_NAME, DEVICE_NAME.encode("utf-8")),
            (AdvertisingData.MANUFACTURER_SPECIFIC_DATA, mfg),
        ]))
        scan_resp = bytes(AdvertisingData([
            (AdvertisingData.COMPLETE_LIST_OF_128_BIT_SERVICE_CLASS_UUIDS, bytes(UUID(NUS_SERVICE))),
        ]))
        await device.start_advertising(
            advertising_type=AdvertisingType.UNDIRECTED_CONNECTABLE_SCANNABLE,
            own_address_type=OwnAddressType.PUBLIC,
            auto_restart=True,
            advertising_data=adv,
            scan_response_data=scan_resp,
        )

        print(f"Advertising emulated {MODEL['display']} '{DEVICE_NAME}' (type {DEVICE_TYPE:#04x}, "
              f"encrypted) on netsim. Connect in E-Tune; pairing auto-confirms. Ctrl+C to stop.")
        await asyncio.get_event_loop().create_future()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\nStopped.")
