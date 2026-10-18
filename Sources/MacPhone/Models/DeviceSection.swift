import Foundation

enum AppSection: String, CaseIterable, Identifiable {
    case bridge
    case running
    case android
    case simulators
    case setup

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bridge: "Bluetooth Bridge"
        case .running: "Running"
        case .android: "Android Emulators"
        case .simulators: "Simulators"
        case .setup: "Setup"
        }
    }

    var symbol: String {
        switch self {
        case .bridge: "dot.radiowaves.left.and.right"
        case .running: "play.circle"
        case .android: "smartphone"
        case .simulators: "iphone"
        case .setup: "checklist"
        }
    }
}
