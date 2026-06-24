import Foundation
import CoreBluetooth

/// A peripheral seen during scanning, before/while it is connected.
struct DiscoveredPeripheral: Identifiable, Hashable {
    let id: UUID
    var name: String
    var rssi: Int
    var advertisedServices: [String]
    var isConnectable: Bool
    var lastSeen: Date

    var displayName: String {
        name.isEmpty ? "Unnamed (\(id.uuidString.prefix(8)))" : name
    }
}

/// A characteristic discovered on a connected peripheral.
struct BLECharacteristic: Identifiable, Hashable {
    let uuid: CBUUID
    let serviceUUID: CBUUID
    var properties: [String]
    var isNotifying: Bool
    var lastValueHex: String?

    /// Stable identity across GATT rebuilds so SwiftUI preserves row state and selection
    /// instead of treating every value update as a brand-new row.
    var id: String { "\(serviceUUID.uuidString)/\(uuid.uuidString)" }
    var displayName: String { uuid.uuidString }
}

/// A service discovered on a connected peripheral, with its characteristics.
struct BLEService: Identifiable, Hashable {
    let uuid: CBUUID
    var characteristics: [BLECharacteristic]

    var id: String { uuid.uuidString }
    var displayName: String { uuid.uuidString }
}

/// High-level connection lifecycle for the UI.
enum BLEConnectionState: Equatable {
    case idle
    case scanning
    case connecting(String)
    case connected(String)
    case disconnected

    var label: String {
        switch self {
        case .idle: "Idle"
        case .scanning: "Scanning…"
        case .connecting(let name): "Connecting to \(name)…"
        case .connected(let name): "Connected to \(name)"
        case .disconnected: "Disconnected"
        }
    }
}

/// A timestamped event for the bridge activity log.
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
    /// Human-readable property names for display.
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

extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    init?(hexString: String) {
        let cleaned = hexString.filter { !$0.isWhitespace }
        guard cleaned.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self = Data(bytes)
    }
}
