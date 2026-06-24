import Foundation

enum DeviceSection: String, CaseIterable, Identifiable {
    case overview
    case setup
    case android
    case ios
    case bluetooth

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .setup: "Setup"
        case .android: "Android"
        case .ios: "iOS"
        case .bluetooth: "Bluetooth"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .setup: "checklist"
        case .android: "app.badge"
        case .ios: "iphone"
        case .bluetooth: "dot.radiowaves.left.and.right"
        }
    }
}
