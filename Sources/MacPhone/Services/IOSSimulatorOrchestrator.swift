import Foundation

struct IOSSimulatorOrchestrator {
    private let runner = CommandRunner()

    func discover() async -> DiscoveryResult {
        do {
            let result = try await runner.run("/usr/bin/xcrun", ["simctl", "list", "devices", "--json"])
            guard result.succeeded else {
                return DiscoveryResult(
                    devices: [],
                    issues: [
                        DiscoveryIssue(severity: .warning, message: "Could not list iOS simulators: \(result.standardError.trimmedOneLine)")
                    ]
                )
            }

            return DiscoveryResult(devices: parseDevices(result.standardOutput), issues: [])
        } catch {
            return DiscoveryResult(
                devices: [],
                issues: [
                    DiscoveryIssue(severity: .warning, message: "Xcode command line tools not available for iOS Simulator discovery.")
                ]
            )
        }
    }

    private func parseDevices(_ json: String) -> [MobileDevice] {
        guard
            let data = json.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let devicesByRuntime = root["devices"] as? [String: [[String: Any]]]
        else {
            return []
        }

        return devicesByRuntime.flatMap { runtime, devices in
            devices.compactMap { item -> MobileDevice? in
                guard
                    let udid = item["udid"] as? String,
                    let name = item["name"] as? String,
                    let state = item["state"] as? String
                else {
                    return nil
                }

                let isAvailable = item["isAvailable"] as? Bool ?? true
                guard isAvailable else { return nil }

                return MobileDevice(
                    id: "ios-sim-\(udid)",
                    name: name,
                    platform: .ios,
                    runtime: readableRuntime(runtime),
                    state: state,
                    identifier: udid
                )
            }
        }
    }

    private func readableRuntime(_ runtime: String) -> String {
        runtime
            .replacingOccurrences(of: "com.apple.CoreSimulator.SimRuntime.", with: "")
            .replacingOccurrences(of: "-", with: " ")
    }
}
