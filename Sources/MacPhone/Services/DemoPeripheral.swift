import Foundation
@preconcurrency import CoreBluetooth

/// A made-up BLE device for trying the emulator path without hardware: the standard
/// Battery service with a level that drains while subscribed, plus a read/write
/// characteristic that echoes back what was written.
struct DemoPeripheral {
    static let name = "MacPhone Demo"
    static let serviceUUID = CBUUID(string: "180F")
    static let batteryUUID = CBUUID(string: "2A19")
    static let echoServiceUUID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    static let echoUUID = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")

    private(set) var battery: UInt8 = 87
    private(set) var echo = Data([0x00])

    var services: [BLEService] {
        [
            BLEService(uuid: Self.serviceUUID, characteristics: [
                BLECharacteristic(uuid: Self.batteryUUID, serviceUUID: Self.serviceUUID,
                                  properties: ["read", "notify"], isNotifying: false,
                                  lastValueHex: Data([battery]).hexString),
            ]),
            BLEService(uuid: Self.echoServiceUUID, characteristics: [
                BLECharacteristic(uuid: Self.echoUUID, serviceUUID: Self.echoServiceUUID,
                                  properties: ["read", "write"], isNotifying: false,
                                  lastValueHex: echo.hexString),
            ]),
        ]
    }

    func value(for characteristic: CBUUID) -> Data {
        characteristic == Self.batteryUUID ? Data([battery]) : echo
    }

    mutating func write(_ data: Data) {
        echo = data
    }

    /// One step of the simulated drain; wraps from 5 % back to 100 %.
    mutating func tick() -> Data {
        battery = battery > 5 ? battery - 1 : 100
        return Data([battery])
    }
}
