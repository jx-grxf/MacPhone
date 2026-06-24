import Foundation

/// An in-app emulated Xiaomi M365 e-scooter, so the whole MacPhone path (app → server →
/// netsim bridge → emulator) can be exercised against a model-matching app like XiaoDash
/// without any real BLE hardware. It exposes the Nordic UART Service and answers the
/// unencrypted M365 packet protocol; its advertisement (name + manufacturer data) is what
/// lets XiaoDash recognise it as an original M365.
///
/// Wire format (app → 6e400002 write, scooter → 6e400003 notify):
///
///     55 AA LEN ADDR CMD [PAYLOAD…] CK0 CK1
///
/// LEN = 1(CMD) + payload (ADDR not counted); checksum = (sum of bytes after 55AA except
/// the checksum) XOR 0xFFFF, little-endian. ADDR 0x20 = ESC, 0x22 = BMS; replies 0x23/0x25.
struct M365Engine {
    // Nordic UART Service used by M365-compatible scooters.
    static let nusService = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
    static let nusTxNotify = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"  // scooter → app
    static let nusRxWrite = "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"   // app → scooter

    // Recognition data XiaoDash matches: company 0x424E, byte[0] = device type
    // (0x20 = original M365 / "ESCOOTER"), byte[1] = sub/version.
    static let advertisedName = "MIScooter1234"
    static let manufacturerDataHex = "4e422000"
    static let xiaomiServiceData16 = "FE95"

    // A half-charged, idle scooter, served as standard M365 register blocks.
    private static let batteryPercent: UInt16 = 86
    private static let voltageCentivolt: UInt16 = 4020   // 40.20 V (units of 10 mV)
    private static let remainingMah: UInt16 = 5200
    private static let cellMillivolt: UInt16 = 4020
    private static let tripMeters: UInt16 = 1234
    private static let totalMeters: UInt32 = 152_380
    private static let frameTempCx10: UInt16 = 235       // 23.5 °C
    private static let bmsTempC: UInt8 = 23
    private static let firmware: UInt16 = 0x0143
    private static let tempBias: UInt8 = 20
    private static let serial = Array("16273/00001234".utf8)

    private let esc: [UInt8]
    private let bms: [UInt8]

    init() {
        var esc = [UInt8](repeating: 0, count: 0x200)
        var bms = [UInt8](repeating: 0, count: 0x200)

        func u16(_ mem: inout [UInt8], _ reg: Int, _ value: UInt16) {
            mem[reg * 2] = UInt8(value & 0xFF)
            mem[reg * 2 + 1] = UInt8(value >> 8)
        }
        func u32(_ mem: inout [UInt8], _ reg: Int, _ value: UInt32) {
            for i in 0..<4 { mem[reg * 2 + i] = UInt8((value >> (8 * i)) & 0xFF) }
        }
        func blob(_ mem: inout [UInt8], _ reg: Int, _ data: [UInt8]) {
            for (i, byte) in data.enumerated() where reg * 2 + i < mem.count { mem[reg * 2 + i] = byte }
        }

        // ESC / controller (addr 0x20)
        blob(&esc, 0x10, Self.serial)
        u16(&esc, 0x1A, Self.firmware)
        u16(&esc, 0x25, Self.tripMeters)
        u32(&esc, 0x29, Self.totalMeters)
        u16(&esc, 0xB4, Self.batteryPercent)
        u16(&esc, 0xB7, UInt16(Self.totalMeters & 0xFFFF))
        u16(&esc, 0xB8, UInt16(Self.totalMeters >> 16))
        u16(&esc, 0xB9, Self.tripMeters)
        u16(&esc, 0xBB, Self.frameTempCx10)
        u16(&esc, 0xBE, Self.frameTempCx10)

        // BMS / battery (addr 0x22)
        blob(&bms, 0x10, Self.serial)
        u16(&bms, 0x31, Self.remainingMah)
        u16(&bms, 0x32, Self.batteryPercent)
        u16(&bms, 0x34, Self.voltageCentivolt)
        let t = UInt16(Self.bmsTempC + Self.tempBias)
        u16(&bms, 0x35, t | (t << 8))
        for cell in 0..<10 { u16(&bms, 0x40 + cell, Self.cellMillivolt) }

        self.esc = esc
        self.bms = bms
    }

    private static func checksum(_ body: [UInt8]) -> [UInt8] {
        let sum = body.reduce(0) { $0 + Int($1) }
        let cs = (sum ^ 0xFFFF) & 0xFFFF
        return [UInt8(cs & 0xFF), UInt8((cs >> 8) & 0xFF)]
    }

    private static func frame(addr: UInt8, cmd: UInt8, payload: [UInt8]) -> [UInt8] {
        let body: [UInt8] = [UInt8((1 + payload.count) & 0xFF), addr, cmd] + payload
        return [0x55, 0xAA] + body + checksum(body)
    }

    private func registerBytes(addr: UInt8, register: Int, length: Int) -> [UInt8] {
        let bank = (addr == 0x22) ? bms : esc
        let start = register * 2
        var out = [UInt8](repeating: 0, count: length)
        for i in 0..<length where start + i < bank.count { out[i] = bank[start + i] }
        return out
    }

    /// Answer a read command frame; returns the reply frames to notify back (usually one).
    func reply(to data: [UInt8]) -> [[UInt8]] {
        guard data.count >= 7, data[0] == 0x55, data[1] == 0xAA else { return [] }
        let addr = data[3], cmd = data[4]
        guard cmd == 0x01 else { return [] }
        let register = Int(data[5])
        let length = max(1, min(Int(data[6]), 64))
        let replyAddr: UInt8 = addr == 0x20 ? 0x23 : (addr == 0x22 ? 0x25 : addr)
        return [Self.frame(addr: replyAddr, cmd: 0x01, payload: registerBytes(addr: addr, register: register, length: length))]
    }
}
