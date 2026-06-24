import Foundation

struct MobileDevice: Identifiable, Hashable {
    let id: String
    let name: String
    let platform: MobilePlatform
    let runtime: String
    let state: String
    let identifier: String

    var displayIdentifier: String {
        identifier.isEmpty ? "-" : identifier
    }

    /// True when the device is a live, running instance (booted simulator / running AVD).
    var isRunning: Bool {
        switch platform {
        case .ios: state.caseInsensitiveCompare("Booted") == .orderedSame
        case .android: state.hasPrefix("Running")
        }
    }

    /// True when the device represents something that can be booted (a definition that is
    /// not currently running).
    var canBoot: Bool {
        switch platform {
        case .ios: !isRunning && state.caseInsensitiveCompare("Booted") != .orderedSame
        case .android: runtime == "AVD" && !isRunning
        }
    }

    /// True when erasing the device is meaningful: iOS simulators always, but Android only
    /// when it is AVD-backed (a physical/adb-only target can't be wiped via `-wipe-data`).
    var canWipe: Bool {
        switch platform {
        case .ios: true
        case .android: runtime == "AVD"
        }
    }
}

enum MobilePlatform: String, Hashable {
    case android
    case ios

    var symbol: String {
        switch self {
        case .android: "app.badge"
        case .ios: "iphone"
        }
    }

    var displayName: String {
        switch self {
        case .android: "Android emulator"
        case .ios: "iOS simulator"
        }
    }
}

struct DiscoveryIssue: Identifiable, Hashable {
    let id = UUID()
    let severity: DiscoverySeverity
    let message: String
}

enum DiscoverySeverity: Hashable {
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
