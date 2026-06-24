#!/usr/bin/env python3
"""
Emulated Segway-Ninebot Max G2 scooter on the Android emulator's netsim controller.

Standalone test fixture for the *encrypted* Ninebot transport. It advertises like a Max G2
(company 0x424E, device type 0x83), runs the NinebotCrypto session handshake, and answers
telemetry reads — so E-Tune (or any client speaking the protocol) can pair and read data
without real hardware.

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
DEVICE_TYPE = int(os.environ.get("NB_TYPE", "0x83"), 0)   # 0x83 = Max G2 (encrypted)
DEVICE_SUBTYPE = int(os.environ.get("NB_SUBTYPE", "0"), 0)
DEVICE_NAME = os.environ.get("NB_NAME", "NBSC231234567")  # both sides derive the key from this
DEVICE_ADDRESS = os.environ.get("NB_ADDR", "F0:F1:F2:F3:F4:F7")
SERIAL = os.environ.get("NB_SERIAL", "N4GUB2341C0543").encode("ascii")[:14].ljust(14, b"\x00")

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


# --- Telemetry the fake Max G2 reports (keyed by source address + register) ---
ESC, BMS, PHONE = 0x20, 0x22, 0x3E
TELEMETRY = {
    (ESC, 0x26): struct.pack("<H", 0),        # speed (km/h x10) — idle
    (ESC, 0xB5): struct.pack("<H", 73),       # battery %
    (BMS, 0x34): struct.pack("<H", 4180),     # pack voltage (x100) → 41.80 V
    (ESC, 0xB7): struct.pack("<I", 152380),   # total (m) → 152.38 km
    (ESC, 0xB9): struct.pack("<I", 1234),     # trip (m) → 1.234 km
    (ESC, 0xB0): bytes(16),                    # status block (debug read)
}
WRITE_NAMES = {(0x20, 0x7A): "BEEP/HORN", (0x20, 0x70): "HEADLIGHT", (0x20, 0x71): "BLINKER"}


class FakeMaxG2:
    def __init__(self, send_plain):
        self.crypto = NinebotCrypto(DEVICE_NAME)
        self.send_plain = send_plain          # async callback(plaintext_frame)
        self.rx = bytearray()
        self.ready = False

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
            payload = TELEMETRY.get((target, reg), bytes(length))[:max(length, len(TELEMETRY.get((target, reg), b"")))]
            if not payload:
                payload = bytes(length)
            reply = bytes([0x5A, 0xA5, len(payload), target, PHONE, 0x01, reg]) + payload
            await self.send_plain(reply)
            print(f"[nb] read {target:#04x}/{reg:#04x} → {payload.hex(' ')}")
        elif cmd == 0x03:                                 # write (tuning / fun command)
            name = WRITE_NAMES.get((dst, arg), "WRITE")
            value = p[7:].hex(" ")
            print(f"[nb] *** {name} command received: reg {arg:#04x} = {value} ***")


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

        print(f"Advertising emulated Ninebot Max G2 '{DEVICE_NAME}' (type {DEVICE_TYPE:#04x}, "
              f"encrypted) on netsim. Connect in E-Tune; pairing auto-confirms. Ctrl+C to stop.")
        await asyncio.get_event_loop().create_future()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\nStopped.")
