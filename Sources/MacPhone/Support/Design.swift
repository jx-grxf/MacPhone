import SwiftUI

/// Spacing, radii and motion in one place. Values follow the other Mac apps in this family
/// (PortPirate, BriskEdit) so MacPhone feels like a sibling, not a one-off.
enum Design {
    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 28
    }

    enum Radius {
        /// Grouped content blocks.
        static let card: CGFloat = 14
        /// Rows and inline panels inside a card.
        static let row: CGFloat = 11
    }

    enum Motion {
        static let hover = Animation.snappy(duration: 0.16)
        static let expand = Animation.snappy(duration: 0.22)
    }

    /// Hover fill: visible on both appearances without competing with the selection colour.
    static let hoverFill = Color.primary.opacity(0.06)
    static let cardFill = Color(nsColor: .controlBackgroundColor)
    static let separator = Color(nsColor: .separatorColor)
}

extension DiscoverySeverity {
    var tint: Color {
        switch self {
        case .info: .secondary
        case .warning: .orange
        case .error: .red
        }
    }
}

extension DeviceState {
    var tint: Color {
        switch self {
        case .booted: .green
        case .booting, .shuttingDown: .orange
        case .shutdown: .secondary
        case .unavailable: .red
        }
    }
}
