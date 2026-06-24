import SwiftUI

extension DiscoverySeverity {
    var foregroundStyle: Color {
        switch self {
        case .info: .secondary
        case .warning: .orange
        case .error: .red
        }
    }
}
