import Foundation

struct DiscoveryResult {
    var devices: [MobileDevice]
    var issues: [DiscoveryIssue]

    static let empty = DiscoveryResult(devices: [], issues: [])
}
