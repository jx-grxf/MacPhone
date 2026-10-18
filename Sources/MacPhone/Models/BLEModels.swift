import Foundation
@preconcurrency import CoreBluetooth

struct DiscoveredPeripheral: Identifiable, Hashable {
    let id: UUID
    var name: String
    var rssi: Int
    var advertisedServices: [String]
    var isConnectable: Bool

    var displayName: String {
        name.isEmpty ? "Unnamed \(id.uuidString.prefix(8))" : name
    }
}

struct BLECharacteristic: Identifiable, Hashable {
    let uuid: CBUUID
    let serviceUUID: CBUUID
    var properties: [String]
    var isNotifying: Bool
    var lastValueHex: String?

    /// Stable across GATT rebuilds, so a value update does not recreate the row.
    var id: String { BLECharacteristic.key(service: serviceUUID, characteristic: uuid) }
    var displayName: String { BluetoothNames.characteristic(uuid) }
    var canRead: Bool { properties.contains("read") }
    var canWrite: Bool { properties.contains("write") || properties.contains("writeNR") }
    var canNotify: Bool { properties.contains("notify") || properties.contains("indicate") }

    static func key(service: CBUUID, characteristic: CBUUID) -> String {
        "\(service.uuidString)/\(characteristic.uuidString)"
    }
}

struct BLEService: Identifiable, Hashable {
    let uuid: CBUUID
    var characteristics: [BLECharacteristic]

    var id: String { uuid.uuidString }
    var displayName: String { BluetoothNames.service(uuid) }
}

enum BLEConnectionState: Equatable {
    case idle
    case scanning
    case connecting(String)
    case connected(String)
    /// The bridge asked for a fresh session; the link is being re-established.
    case reconnecting(String)
    case demo

    var label: String {
        switch self {
        case .idle: "Not connected"
        case .scanning: "Scanning"
        case .connecting(let name): "Connecting to \(name)"
        case .connected(let name): "Connected to \(name)"
        case .reconnecting(let name): "Reconnecting to \(name)"
        case .demo: "Demo device active"
        }
    }

    var hasDevice: Bool {
        switch self {
        case .connected, .reconnecting, .demo: true
        default: false
        }
    }
}

struct BLELogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let direction: Direction
    let message: String

    enum Direction {
        case info, outgoing, incoming, error

        var symbol: String {
            switch self {
            case .info: "info.circle"
            case .outgoing: "arrow.up.circle"
            case .incoming: "arrow.down.circle"
            case .error: "exclamationmark.triangle"
            }
        }
    }
}

extension CBCharacteristicProperties {
    var labels: [String] {
        var result: [String] = []
        if contains(.read) { result.append("read") }
        if contains(.write) { result.append("write") }
        if contains(.writeWithoutResponse) { result.append("writeNR") }
        if contains(.notify) { result.append("notify") }
        if contains(.indicate) { result.append("indicate") }
        return result
    }
}

/// Names for the assigned numbers people actually meet; everything else shows its UUID.
enum BluetoothNames {
    static func service(_ uuid: CBUUID) -> String {
        services[uuid.uuidString.uppercased()].map { "\($0) (\(uuid.uuidString))" } ?? uuid.uuidString
    }

    static func characteristic(_ uuid: CBUUID) -> String {
        characteristics[uuid.uuidString.uppercased()].map { "\($0) (\(uuid.uuidString))" } ?? uuid.uuidString
    }

    private static let services = [
        "1800": "Generic Access", "1801": "Generic Attribute", "180A": "Device Information",
        "180F": "Battery", "180D": "Heart Rate", "1816": "Cycling Speed and Cadence",
        "1818": "Cycling Power", "1826": "Fitness Machine", "181A": "Environmental Sensing",
        "1812": "Human Interface Device", "FE59": "Nordic DFU",
        "6E400001-B5A3-F393-E0A9-E50E24DCCA9E": "Nordic UART",
    ]

    private static let characteristics = [
        "2A00": "Device Name", "2A01": "Appearance", "2A19": "Battery Level",
        "2A24": "Model Number", "2A25": "Serial Number", "2A26": "Firmware Revision",
        "2A27": "Hardware Revision", "2A28": "Software Revision", "2A29": "Manufacturer Name",
        "2A37": "Heart Rate Measurement", "2A38": "Body Sensor Location",
        "6E400002-B5A3-F393-E0A9-E50E24DCCA9E": "UART RX", "6E400003-B5A3-F393-E0A9-E50E24DCCA9E": "UART TX",
    ]
}

extension Data {
    var hexString: String {
        let digits = Array("0123456789abcdef".utf8)
        var output = [UInt8]()
        output.reserveCapacity(count * 2)
        for byte in self {
            output.append(digits[Int(byte >> 4)])
            output.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: output, as: UTF8.self)
    }

    init?(hexString: String) {
        let cleaned = Array(hexString.filter { !$0.isWhitespace }.utf8)
        guard cleaned.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(cleaned.count / 2)
        var index = 0
        while index < cleaned.count {
            guard let high = Self.nibble(cleaned[index]), let low = Self.nibble(cleaned[index + 1]) else { return nil }
            bytes.append(high << 4 | low)
            index += 2
        }
        self = Data(bytes)
    }

    private static func nibble(_ ascii: UInt8) -> UInt8? {
        switch ascii {
        case 48...57: ascii - 48
        case 65...70: ascii - 55
        case 97...102: ascii - 87
        default: nil
        }
    }
}
