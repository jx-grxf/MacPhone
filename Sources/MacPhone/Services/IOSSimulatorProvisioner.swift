import Foundation

struct IOSSimulatorProvisioner {
    private let runner = CommandRunner()

    struct Runtime: Identifiable, Hashable {
        let id: String
        let name: String
        let version: String
    }

    struct DeviceType: Identifiable, Hashable {
        let id: String
        let name: String
        let minimumRuntimeVersion: String?
        let maximumRuntimeVersion: String?
    }

    struct Catalog: Equatable {
        var runtimes: [Runtime]
        var deviceTypes: [DeviceType]

        static let empty = Catalog(runtimes: [], deviceTypes: [])

        func compatibleDeviceTypes(forRuntimeID runtimeID: String) -> [DeviceType] {
            guard let runtime = runtimes.first(where: { $0.id == runtimeID }) else {
                return []
            }
            return deviceTypes.filter { deviceType in
                if let minimum = deviceType.minimumRuntimeVersion,
                   runtime.version.compare(minimum, options: .numeric) == .orderedAscending {
                    return false
                }
                if let maximum = deviceType.maximumRuntimeVersion,
                   runtime.version.compare(maximum, options: .numeric) == .orderedDescending {
                    return false
                }
                return true
            }
        }
    }

    struct Request: Equatable {
        var name: String
        var deviceTypeIdentifier: String
        var runtimeIdentifier: String
    }

    enum ProvisionError: LocalizedError {
        case xcodeMissing
        case commandFailed(String)
        case unreadableCatalog
        case noRuntime
        case noDeviceType
        case invalidName

        var errorDescription: String? {
            switch self {
            case .xcodeMissing:
                "Full Xcode is required. Install Xcode, select it in Xcode Settings, and retry."
            case .commandFailed(let message):
                message
            case .unreadableCatalog:
                "Could not read the installed iOS Simulator catalog."
            case .noRuntime:
                "No iOS Simulator runtime is installed. Download one first."
            case .noDeviceType:
                "No compatible iPhone simulator device type is available."
            case .invalidName:
                "Enter a name for the new iOS simulator."
            }
        }
    }

    static var fullXcodeInstalled: Bool {
        commandSucceeds("/usr/bin/xcodebuild", ["-version"])
            && commandSucceeds("/usr/bin/xcrun", ["--find", "simctl"])
    }

    static var runtimeDownloadInProgress: Bool {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-f", "/usr/bin/xcodebuild -downloadPlatform iOS"]
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
                && !output.fileHandleForReading.readDataToEndOfFile().isEmpty
        } catch {
            return false
        }
    }

    func catalog() async throws -> Catalog {
        guard Self.fullXcodeInstalled else { throw ProvisionError.xcodeMissing }
        let result = try await runner.run(
            "/usr/bin/xcrun",
            ["simctl", "list", "--json", "devicetypes", "runtimes"],
            timeout: 30
        )
        guard result.succeeded else {
            throw ProvisionError.commandFailed(
                "simctl list failed: \(result.standardError.trimmedOneLine)"
            )
        }
        return try parseCatalog(result.standardOutput)
    }

    func downloadLatestRuntime(
        onLog: @escaping @Sendable (String) -> Void
    ) async throws {
        guard Self.fullXcodeInstalled else { throw ProvisionError.xcodeMissing }
        onLog("Downloading the latest iOS Simulator runtime from Apple…")
        onLog("This is a large download and can take several minutes.")
        let code = try await runner.runStreaming(
            "/usr/bin/xcodebuild",
            ["-downloadPlatform", "iOS"],
            timeout: 7_200,
            onLine: onLog
        )
        guard code == 0 else {
            throw ProvisionError.commandFailed(
                "xcodebuild -downloadPlatform iOS failed (exit \(code))."
            )
        }
        onLog("iOS Simulator runtime installed.")
    }

    func create(
        _ request: Request,
        onLog: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        guard Self.fullXcodeInstalled else { throw ProvisionError.xcodeMissing }
        let name = request.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ProvisionError.invalidName }
        guard !request.runtimeIdentifier.isEmpty else { throw ProvisionError.noRuntime }
        guard !request.deviceTypeIdentifier.isEmpty else { throw ProvisionError.noDeviceType }

        onLog("Creating \(name)…")
        let result = try await runner.run(
            "/usr/bin/xcrun",
            [
                "simctl", "create", name,
                request.deviceTypeIdentifier,
                request.runtimeIdentifier
            ],
            timeout: 60
        )
        guard result.succeeded else {
            throw ProvisionError.commandFailed(
                "simctl create failed: \(result.standardError.trimmedOneLine)"
            )
        }

        let udid = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !udid.isEmpty else {
            throw ProvisionError.commandFailed("simctl create returned no device identifier.")
        }
        onLog("Created iOS simulator \(name) (\(udid)).")
        return udid
    }

    private func parseCatalog(_ json: String) throws -> Catalog {
        guard let data = json.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawRuntimes = root["runtimes"] as? [[String: Any]],
              let rawDeviceTypes = root["devicetypes"] as? [[String: Any]]
        else {
            throw ProvisionError.unreadableCatalog
        }

        let runtimes = rawRuntimes.compactMap { item -> Runtime? in
            guard (item["isAvailable"] as? Bool ?? true),
                  let identifier = item["identifier"] as? String,
                  identifier.contains("SimRuntime.iOS"),
                  let name = item["name"] as? String
            else {
                return nil
            }
            return Runtime(
                id: identifier,
                name: name,
                version: item["version"] as? String ?? name.replacingOccurrences(of: "iOS ", with: "")
            )
        }
        .sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }

        let deviceTypes = rawDeviceTypes.compactMap { item -> DeviceType? in
            guard let identifier = item["identifier"] as? String,
                  let name = item["name"] as? String,
                  (item["productFamily"] as? String == "iPhone" || name.hasPrefix("iPhone"))
            else {
                return nil
            }
            return DeviceType(
                id: identifier,
                name: name,
                minimumRuntimeVersion: item["minRuntimeVersionString"] as? String,
                maximumRuntimeVersion: item["maxRuntimeVersionString"] as? String
            )
        }

        return Catalog(runtimes: runtimes, deviceTypes: deviceTypes)
    }

    private static func commandSucceeds(_ executable: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
