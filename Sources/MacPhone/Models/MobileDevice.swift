import Foundation

struct MobileDevice: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        /// An Xcode simulator; `identifier` is its UDID.
        case simulator
        /// An Android Virtual Device; `identifier` is the AVD name.
        case avd
        /// Something adb sees that is not one of our AVDs (a USB phone, a foreign emulator).
        case adbOnly
    }

    let id: String
    let name: String
    let kind: Kind
    let family: DeviceFamily
    /// "iOS 27.0", "watchOS 27.0", "Android 15".
    let osVersion: String
    let state: DeviceState
    let identifier: String
    /// The adb serial while an Android device is online.
    let serial: String?

    var platform: MobilePlatform { kind == .simulator ? .apple : .android }
    var isRunning: Bool { state == .booted }
    var isTransitioning: Bool { state == .booting || state == .shuttingDown }
    var canBoot: Bool { kind != .adbOnly && state == .shutdown }
    var canStop: Bool { state == .booted || state == .booting }
    var canErase: Bool { kind != .adbOnly }
    var canDelete: Bool { kind != .adbOnly }
}

enum MobilePlatform: String, Hashable, Sendable {
    case android
    case apple
}

enum DeviceFamily: String, CaseIterable, Hashable, Sendable {
    case iPhone, iPad, watch, tv, vision, mac, android, other

    init(simulatorTypeIdentifier identifier: String) {
        let id = identifier.lowercased()
        if id.contains("iphone") { self = .iPhone }
        else if id.contains("ipad") { self = .iPad }
        else if id.contains("watch") { self = .watch }
        else if id.contains("apple-tv") || id.contains("appletv") { self = .tv }
        else if id.contains("vision") || id.contains("realitydevice") { self = .vision }
        else { self = .other }
    }

    var title: String {
        switch self {
        case .iPhone: "iPhone"
        case .iPad: "iPad"
        case .watch: "Apple Watch"
        case .tv: "Apple TV"
        case .vision: "Apple Vision"
        case .mac: "Mac"
        case .android: "Android"
        case .other: "Other"
        }
    }

    var symbol: String {
        switch self {
        case .iPhone: "iphone"
        case .iPad: "ipad"
        case .watch: "applewatch"
        case .tv: "appletv"
        case .vision: "vision.pro"
        case .mac: "macbook"
        case .android: "smartphone"
        case .other: "questionmark.square.dashed"
        }
    }
}

enum DeviceState: Hashable, Sendable {
    case shutdown
    case booting
    case booted
    case shuttingDown
    case unavailable(String)

    init(simctl raw: String) {
        switch raw.lowercased() {
        case "booted": self = .booted
        case "booting", "creating": self = .booting
        case "shutting down": self = .shuttingDown
        case "shutdown": self = .shutdown
        default: self = .unavailable(raw)
        }
    }

    var title: String {
        switch self {
        case .shutdown: "Off"
        case .booting: "Starting"
        case .booted: "Running"
        case .shuttingDown: "Stopping"
        case .unavailable(let raw): raw.capitalized
        }
    }

    var symbol: String {
        switch self {
        case .shutdown: "poweroff"
        case .booting, .shuttingDown: "hourglass"
        case .booted: "play.circle.fill"
        case .unavailable: "exclamationmark.triangle"
        }
    }
}

struct DiscoveryIssue: Identifiable, Hashable, Sendable {
    var id: String { message }
    let severity: DiscoverySeverity
    let message: String
}

enum DiscoverySeverity: Hashable, Sendable {
    case info
    case warning
    case error

    var symbol: String {
        switch self {
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle"
        case .error: "xmark.octagon"
        }
    }
}

struct DiscoveryResult: Sendable {
    var devices: [MobileDevice]
    var issues: [DiscoveryIssue]
}

enum SimulatorRuntimeName {
    /// "com.apple.CoreSimulator.SimRuntime.watchOS-27-0" → "watchOS 27.0".
    static func readable(_ identifier: String) -> String {
        let tail = identifier.replacingOccurrences(of: "com.apple.CoreSimulator.SimRuntime.", with: "")
        guard let dash = tail.firstIndex(of: "-") else { return tail }
        var os = String(tail[..<dash])
        if os == "xrOS" { os = "visionOS" }
        let version = tail[tail.index(after: dash)...].replacingOccurrences(of: "-", with: ".")
        return "\(os) \(version)"
    }
}
