import Foundation

/// In-app virtual scooters for exercising the complete MacPhone mirror path without physical BLE
/// hardware. Every profile speaks the plaintext Xiaomi M365 protocol (55 AA frames over Nordic
/// UART) — the path E-Tune's M365 dashboard, tuning, presets and (experimental) field-weakening
/// features drive. Writes are persisted into the register banks and acknowledged, so tuning writes
/// (KERS / cruise / tail light / field weakening) round-trip: a later read reflects them.
struct VirtualScooter {
    // Shared Nordic UART UUIDs. All profiles advertise device type 0x20 so E-Tune drives them with
    // the plaintext M365 protocol (other manufacturer types route to the encrypted Ninebot path).
    static let nusService = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
    static let nusTxNotify = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"
    static let nusRxWrite = "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"
    static let manufacturerDataHex = "4e422000" // company 0x424E, device type 0x20 (M365 family)

    /// Field weakening lives in the custom-firmware config block (ESC 0xBE max current, 0xBF max
    /// speed). E-Tune reads register 0xBE with length 2 and expects [current, maxSpeed]; it writes
    /// 0xBE / 0xBF as single bytes. We model that pair explicitly rather than as raw bank bytes.
    static let fieldWeakeningRegister = 0xBE
    static let fieldWeakeningSpeedRegister = 0xBF

    struct Profile: Identifiable, Hashable {
        let id: String
        let displayName: String
        let summary: String
        let advertisedName: String

        var batteryPercent: UInt16 = 86
        var voltageCentivolt: UInt16 = 4020
        var remainingMah: UInt16 = 5200
        var cellMillivolt: UInt16 = 4020
        var cellCount: Int = 10
        var speedKmhX1000: UInt16 = 0          // ESC 0xB5 (km/h = value / 1000); 0 = parked
        var currentCentiAmp: Int16 = 150        // BMS 0x33 signed (A x100); negative under regen
        var tripMeters: UInt16 = 1234
        var totalMeters: UInt32 = 152_380
        var frameTempCx10: UInt16 = 235         // ESC 0x3E (0.1 C)
        var bmsTempC: UInt8 = 23
        var firmware: UInt16 = 0x0143
        var errorAlarm: UInt16 = 0              // ESC 0xB0 bitfield
        var kers: UInt8 = 1
        var cruise: UInt8 = 0
        var tailLight: UInt8 = 0
        var serial: String = "16273/00001234"
        var hasCustomFirmware: Bool = false
        var fieldWeakeningCurrent: UInt8 = 0    // 0 unless CFW is present
        var fieldWeakeningMaxSpeed: UInt8 = 0
    }

    let profile: Profile
    private var esc: [UInt8]
    private var bms: [UInt8]
    private var fwCurrent: UInt8
    private var fwMaxSpeed: UInt8

    var advertisedName: String { profile.advertisedName }
    var manufacturerDataHex: String { Self.manufacturerDataHex }

    init(profile: Profile) {
        self.profile = profile
        self.fwCurrent = profile.fieldWeakeningCurrent
        self.fwMaxSpeed = profile.fieldWeakeningMaxSpeed

        var esc = [UInt8](repeating: 0, count: 0x200)
        var bms = [UInt8](repeating: 0, count: 0x200)

        func u16(_ memory: inout [UInt8], _ register: Int, _ value: UInt16) {
            memory[register * 2] = UInt8(value & 0xFF)
            memory[register * 2 + 1] = UInt8(value >> 8)
        }
        func u32(_ memory: inout [UInt8], _ register: Int, _ value: UInt32) {
            for index in 0..<4 { memory[register * 2 + index] = UInt8((value >> (8 * index)) & 0xFF) }
        }
        func blob(_ memory: inout [UInt8], _ register: Int, _ data: [UInt8]) {
            for (index, byte) in data.enumerated() where register * 2 + index < memory.count {
                memory[register * 2 + index] = byte
            }
        }

        // ESC bank — registers exactly as E-Tune's M365Protocol reads them.
        blob(&esc, 0x10, Array(profile.serial.utf8)) // serial (14 ASCII)
        u16(&esc, 0x1A, profile.firmware)            // firmware (BCD)
        u16(&esc, 0x25, profile.tripMeters)          // trip meters
        u32(&esc, 0x29, profile.totalMeters)         // total meters
        u16(&esc, 0x3E, profile.frameTempCx10)       // frame temperature (0.1 C)
        // M365 dashboards (XiaoDash etc.) poll the ESC realtime status block with a single
        // contiguous read starting at register 0xB0 and bind each gauge to a fixed offset
        // inside it. Speed, odometer, trip and frame temperature MUST sit at their classic
        // M365-firmware registers (0xB5/0xB7/0xB8/0xB9/0xBB/0xBE) or those gauges read zero.
        u16(&esc, 0xB0, profile.errorAlarm)          // error / alarm bitfield
        u16(&esc, 0xB1, 0)                           // warning code
        u16(&esc, 0xB4, profile.batteryPercent)      // ESC battery %
        u16(&esc, 0xB5, UInt16(bitPattern: Int16(truncatingIfNeeded: Int(profile.speedKmhX1000) / 10))) // speed (km/h x100, signed)
        u16(&esc, 0xB7, UInt16(truncatingIfNeeded: profile.totalMeters & 0xFFFF))  // odometer low word
        u16(&esc, 0xB8, UInt16(truncatingIfNeeded: profile.totalMeters >> 16))     // odometer high word
        u16(&esc, 0xB9, profile.tripMeters)          // trip distance (m)
        u16(&esc, 0xBB, profile.frameTempCx10)       // frame temperature (x10 C)
        u16(&esc, 0xBE, profile.frameTempCx10)       // frame temperature (alt block; exact 0xBE reads are field weakening)
        esc[0x7B * 2] = profile.kers
        esc[0x7C * 2] = profile.cruise
        esc[0x7D * 2] = profile.tailLight

        // BMS bank.
        blob(&bms, 0x10, Array(profile.serial.utf8))
        u16(&bms, 0x18, 7800)                        // design capacity (mAh)
        u16(&bms, 0x19, 7500)                        // full capacity (mAh)
        u16(&bms, 0x1B, 12)                          // charge cycles
        u16(&bms, 0x31, profile.remainingMah)
        u16(&bms, 0x32, profile.batteryPercent)
        u16(&bms, 0x33, UInt16(bitPattern: profile.currentCentiAmp))
        u16(&bms, 0x34, profile.voltageCentivolt)
        let temperature = UInt16(profile.bmsTempC) + 20
        u16(&bms, 0x35, temperature | (temperature << 8))
        for cell in 0..<min(profile.cellCount, 10) { u16(&bms, 0x40 + cell, profile.cellMillivolt) }

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
        // Field weakening pair is modelled explicitly (see fieldWeakeningRegister docs).
        if addr == 0x20 && register == Self.fieldWeakeningRegister {
            let pair = [fwCurrent, fwMaxSpeed]
            return (0..<length).map { $0 < pair.count ? pair[$0] : 0 }
        }
        let bank = addr == 0x22 ? bms : esc
        let start = register * 2
        var output = [UInt8](repeating: 0, count: length)
        for index in 0..<length where start + index < bank.count { output[index] = bank[start + index] }
        return output
    }

    private mutating func applyWrite(addr: UInt8, register: Int, value: [UInt8]) {
        guard let first = value.first else { return }
        if addr == 0x20 && register == Self.fieldWeakeningRegister { fwCurrent = first; return }
        if addr == 0x20 && register == Self.fieldWeakeningSpeedRegister { fwMaxSpeed = first; return }
        let start = register * 2
        if addr == 0x22 {
            for (index, byte) in value.enumerated() where start + index < bms.count { bms[start + index] = byte }
        } else {
            for (index, byte) in value.enumerated() where start + index < esc.count { esc[start + index] = byte }
        }
    }

    /// Handle one inbound frame; returns the notification frame(s) to publish back. Reads answer
    /// with the stored value; writes persist the value and acknowledge so a later read reflects it.
    mutating func reply(to data: [UInt8]) -> [[UInt8]] {
        guard data.count >= 7, data[0] == 0x55, data[1] == 0xAA else { return [] }
        let address = data[3]
        let command = data[4]
        let register = Int(data[5])
        let replyAddress: UInt8 = address == 0x20 ? 0x23 : (address == 0x22 ? 0x25 : address)

        switch command {
        case 0x01: // read
            let length = max(1, min(Int(data[6]), 64))
            return [Self.frame(addr: replyAddress, cmd: 0x01,
                               payload: registerBytes(addr: address, register: register, length: length))]
        case 0x03: // write
            let value = Array(data[6..<(data.count - 2)])
            applyWrite(addr: address, register: register, value: value)
            // Acknowledge so the client's request/response loop completes promptly.
            return [Self.frame(addr: replyAddress, cmd: 0x03, payload: [0x01])]
        default:
            return []
        }
    }
}

/// The selectable catalog of virtual scooters, surfaced in the BLE bridge UI.
enum VirtualScooterCatalog {
    static let profiles: [VirtualScooter.Profile] = [
        VirtualScooter.Profile(
            id: "m365_stock",
            displayName: "Xiaomi M365 (stock)",
            summary: "Healthy stock M365 · KERS/cruise/light tuning · no custom firmware",
            advertisedName: "MIScooter1234"
        ),
        {
            var p = VirtualScooter.Profile(
                id: "pro2_cfw",
                displayName: "Xiaomi Pro 2 (custom firmware)",
                summary: "CFW present · field weakening readable & writable (0xBE/0xBF)",
                advertisedName: "MIScooterPRO2"
            )
            p.batteryPercent = 73
            p.voltageCentivolt = 4180
            p.remainingMah = 12_400
            p.totalMeters = 842_000
            p.tripMeters = 5_120
            p.firmware = 0x0150
            p.kers = 2
            p.cruise = 1
            p.tailLight = 2
            p.serial = "27461/00099887"
            p.hasCustomFirmware = true
            p.fieldWeakeningCurrent = 30
            p.fieldWeakeningMaxSpeed = 35
            return p
        }(),
        {
            var p = VirtualScooter.Profile(
                id: "m365_1s",
                displayName: "Xiaomi 1S",
                summary: "1S defaults · full battery · cruise on",
                advertisedName: "MIScooter1S55"
            )
            p.batteryPercent = 99
            p.voltageCentivolt = 4190
            p.cellMillivolt = 4190
            p.remainingMah = 7_650
            p.totalMeters = 31_240
            p.firmware = 0x0148
            p.cruise = 1
            p.serial = "31882/00012345"
            return p
        }(),
        {
            var p = VirtualScooter.Profile(
                id: "m365_fault",
                displayName: "M365 (low battery + fault)",
                summary: "8% · regen current · error/alarm set — exercises edge telemetry",
                advertisedName: "MIScooterERR9"
            )
            p.batteryPercent = 8
            p.voltageCentivolt = 3320
            p.cellMillivolt = 3320
            p.remainingMah = 480
            p.currentCentiAmp = -350 // braking / regen
            p.frameTempCx10 = 512
            p.bmsTempC = 41
            p.errorAlarm = 0x000A
            p.tailLight = 2
            p.serial = "16273/00000009"
            return p
        }(),
    ]

    static let `default` = profiles[0]

    static func profile(id: String) -> VirtualScooter.Profile {
        profiles.first { $0.id == id } ?? `default`
    }
}
