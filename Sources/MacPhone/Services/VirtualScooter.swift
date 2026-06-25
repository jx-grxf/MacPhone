import Foundation

/// In-app Xiaomi M365 test device for exercising the complete MacPhone mirror
/// path without physical BLE hardware.
struct M365Engine {
    static let nusService = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
    static let nusTxNotify = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"
    static let nusRxWrite = "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"

    static let advertisedName = "MIScooter1234"
    static let manufacturerDataHex = "4e422000"

    private static let batteryPercent: UInt16 = 86
    private static let voltageCentivolt: UInt16 = 4020
    private static let remainingMah: UInt16 = 5200
    private static let cellMillivolt: UInt16 = 4020
    private static let tripMeters: UInt16 = 1234
    private static let totalMeters: UInt32 = 152_380
    private static let frameTempCx10: UInt16 = 235
    private static let bmsTempC: UInt8 = 23
    private static let firmware: UInt16 = 0x0143
    private static let tempBias: UInt8 = 20
    private static let serial = Array("16273/00001234".utf8)

    private let esc: [UInt8]
    private let bms: [UInt8]

    init() {
        var esc = [UInt8](repeating: 0, count: 0x200)
        var bms = [UInt8](repeating: 0, count: 0x200)

        func u16(_ memory: inout [UInt8], _ register: Int, _ value: UInt16) {
            memory[register * 2] = UInt8(value & 0xFF)
            memory[register * 2 + 1] = UInt8(value >> 8)
        }

        func u32(_ memory: inout [UInt8], _ register: Int, _ value: UInt32) {
            for index in 0..<4 {
                memory[register * 2 + index] = UInt8((value >> (8 * index)) & 0xFF)
            }
        }

        func blob(_ memory: inout [UInt8], _ register: Int, _ data: [UInt8]) {
            for (index, byte) in data.enumerated()
            where register * 2 + index < memory.count {
                memory[register * 2 + index] = byte
            }
        }

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

        blob(&bms, 0x10, Self.serial)
        u16(&bms, 0x31, Self.remainingMah)
        u16(&bms, 0x32, Self.batteryPercent)
        u16(&bms, 0x34, Self.voltageCentivolt)
        let temperature = UInt16(Self.bmsTempC + Self.tempBias)
        u16(&bms, 0x35, temperature | (temperature << 8))
        for cell in 0..<10 {
            u16(&bms, 0x40 + cell, Self.cellMillivolt)
        }

        self.esc = esc
        self.bms = bms
    }

    private static func checksum(_ body: [UInt8]) -> [UInt8] {
        let sum = body.reduce(0) { $0 + Int($1) }
        let checksum = (sum ^ 0xFFFF) & 0xFFFF
        return [UInt8(checksum & 0xFF), UInt8((checksum >> 8) & 0xFF)]
    }

    private static func frame(addr: UInt8, cmd: UInt8, payload: [UInt8]) -> [UInt8] {
        let body: [UInt8] = [UInt8((1 + payload.count) & 0xFF), addr, cmd] + payload
        return [0x55, 0xAA] + body + checksum(body)
    }

    private func registerBytes(addr: UInt8, register: Int, length: Int) -> [UInt8] {
        let bank = addr == 0x22 ? bms : esc
        let start = register * 2
        var output = [UInt8](repeating: 0, count: length)
        for index in 0..<length where start + index < bank.count {
            output[index] = bank[start + index]
        }
        return output
    }

    func reply(to data: [UInt8]) -> [[UInt8]] {
        guard data.count >= 7, data[0] == 0x55, data[1] == 0xAA else {
            return []
        }
        let address = data[3]
        guard data[4] == 0x01 else { return [] }
        let register = Int(data[5])
        let length = max(1, min(Int(data[6]), 64))
        let replyAddress: UInt8 = address == 0x20 ? 0x23 : (address == 0x22 ? 0x25 : address)
        return [
            Self.frame(
                addr: replyAddress,
                cmd: 0x01,
                payload: registerBytes(addr: address, register: register, length: length)
            )
        ]
    }
}
