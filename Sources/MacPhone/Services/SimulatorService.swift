import Foundation

/// Everything MacPhone does with Xcode simulators, through `xcrun simctl` only.
struct SimulatorService: Sendable {
    private let runner = CommandRunner()

    struct Runtime: Identifiable, Hashable, Sendable {
        let id: String
        let name: String
        let platform: String
        let version: String
        let deviceTypeIDs: [String]
    }

    struct DeviceType: Identifiable, Hashable, Sendable {
        let id: String
        let name: String
        let family: DeviceFamily
    }

    struct Catalog: Equatable, Sendable {
        var runtimes: [Runtime]
        var deviceTypes: [DeviceType]

        static let empty = Catalog(runtimes: [], deviceTypes: [])

        func deviceTypes(for runtimeID: String) -> [DeviceType] {
            guard let runtime = runtimes.first(where: { $0.id == runtimeID }) else { return [] }
            let supported = Set(runtime.deviceTypeIDs)
            return deviceTypes.filter { supported.contains($0.id) }
        }
    }

    struct CreateRequest: Equatable, Sendable {
        var name: String
        var deviceTypeID: String
        var runtimeID: String
    }

    enum SimulatorError: LocalizedError {
        case xcodeMissing
        case failed(String, String)
        case unreadableOutput
        case invalidName

        var errorDescription: String? {
            switch self {
            case .xcodeMissing:
                "Xcode is not installed or not selected. Install Xcode and open it once."
            case .failed(let action, let detail):
                detail.isEmpty ? "\(action) failed." : "\(action) failed: \(detail)"
            case .unreadableOutput:
                "simctl returned output MacPhone could not read."
            case .invalidName:
                "Enter a name for the simulator."
            }
        }
    }

    // MARK: Toolchain

    static func xcodeReady() async -> Bool {
        let runner = CommandRunner()
        guard let version = try? await runner.run("/usr/bin/xcodebuild", ["-version"], timeout: 15),
              version.succeeded,
              let simctl = try? await runner.run("/usr/bin/xcrun", ["--find", "simctl"], timeout: 15)
        else { return false }
        return simctl.succeeded
    }

    static func runtimeDownloadInProgress() async -> Bool {
        let result = try? await CommandRunner().run("/usr/bin/pgrep", ["-f", "xcodebuild -downloadPlatform"], timeout: 5)
        return result?.succeeded == true
    }

    // MARK: Discovery

    func discover() async -> DiscoveryResult {
        do {
            let result = try await runner.run("/usr/bin/xcrun", ["simctl", "list", "devices", "--json"], timeout: 30)
            guard result.succeeded else {
                return DiscoveryResult(devices: [], issues: [
                    DiscoveryIssue(severity: .warning, message: "Could not list simulators: \(result.standardError.trimmedOneLine)")
                ])
            }
            return DiscoveryResult(devices: Self.parseDevices(result.standardOutput), issues: [])
        } catch {
            return DiscoveryResult(devices: [], issues: [
                DiscoveryIssue(severity: .warning, message: "Xcode command line tools are missing, so simulators can't be listed.")
            ])
        }
    }

    static func parseDevices(_ json: String) -> [MobileDevice] {
        guard let root = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let byRuntime = root["devices"] as? [String: [[String: Any]]]
        else { return [] }

        return byRuntime.flatMap { runtime, devices in
            devices.compactMap { item -> MobileDevice? in
                guard let udid = item["udid"] as? String,
                      let name = item["name"] as? String,
                      let state = item["state"] as? String,
                      item["isAvailable"] as? Bool ?? true
                else { return nil }
                let typeID = item["deviceTypeIdentifier"] as? String ?? name
                return MobileDevice(
                    id: "sim-\(udid)",
                    name: name,
                    kind: .simulator,
                    family: DeviceFamily(simulatorTypeIdentifier: typeID),
                    osVersion: SimulatorRuntimeName.readable(runtime),
                    state: DeviceState(simctl: state),
                    identifier: udid,
                    serial: nil
                )
            }
        }
    }

    // MARK: Lifecycle

    func boot(_ udid: String) async throws {
        let result = try await simctl(["boot", udid], timeout: 60)
        if !result.succeeded, !result.standardError.localizedCaseInsensitiveContains("current state: booted") {
            throw SimulatorError.failed("Starting the simulator", result.standardError.trimmedOneLine)
        }
        try? await show(udid)
    }

    func shutdown(_ udid: String) async throws {
        let result = try await simctl(["shutdown", udid], timeout: 60)
        if !result.succeeded, !result.standardError.localizedCaseInsensitiveContains("current state: shutdown") {
            throw SimulatorError.failed("Stopping the simulator", result.standardError.trimmedOneLine)
        }
    }

    func erase(_ udid: String, isRunning: Bool) async throws {
        if isRunning { try await shutdown(udid) }
        try await check(simctl(["erase", udid], timeout: 120), "Erasing the simulator")
    }

    func delete(_ udid: String, isRunning: Bool) async throws {
        if isRunning { try await shutdown(udid) }
        try await check(simctl(["delete", udid], timeout: 120), "Deleting the simulator")
    }

    func deleteUnavailable() async throws {
        try await check(simctl(["delete", "unavailable"], timeout: 120), "Removing unavailable simulators")
    }

    func rename(_ udid: String, to name: String) async throws {
        try await check(simctl(["rename", udid, name]), "Renaming the simulator")
    }

    func clone(_ udid: String, as name: String) async throws {
        try await check(simctl(["clone", udid, name], timeout: 300), "Duplicating the simulator")
    }

    /// Brings Simulator.app forward with this device's window.
    func show(_ udid: String) async throws {
        _ = try await runner.run("/usr/bin/open", ["-a", "Simulator", "--args", "-CurrentDeviceUDID", udid], timeout: 15)
    }

    // MARK: Testing helpers

    func install(_ app: URL, on udid: String) async throws {
        try await check(simctl(["install", udid, app.path], timeout: 300), "Installing \(app.lastPathComponent)")
    }

    func open(_ url: String, on udid: String) async throws {
        try await check(simctl(["openurl", udid, url]), "Opening the URL")
    }

    func screenshot(_ udid: String, to file: URL) async throws {
        try await check(simctl(["io", udid, "screenshot", file.path], timeout: 30), "Taking the screenshot")
    }

    func setAppearance(dark: Bool, on udid: String) async throws {
        try await check(simctl(["ui", udid, "appearance", dark ? "dark" : "light"]), "Changing the appearance")
    }

    /// The marketing status bar: 9:41, full battery, full signal.
    func setCleanStatusBar(_ enabled: Bool, on udid: String) async throws {
        let arguments = enabled
            ? ["status_bar", udid, "override", "--time", "9:41", "--batteryState", "charged",
               "--batteryLevel", "100", "--cellularBars", "4", "--wifiBars", "3", "--dataNetwork", "wifi"]
            : ["status_bar", udid, "clear"]
        try await check(simctl(arguments), "Changing the status bar")
    }

    // MARK: Creating simulators

    func catalog() async throws -> Catalog {
        let result = try await simctl(["list", "--json", "devicetypes", "runtimes"], timeout: 30)
        guard result.succeeded else {
            throw SimulatorError.failed("Reading installed runtimes", result.standardError.trimmedOneLine)
        }
        return try Self.parseCatalog(result.standardOutput)
    }

    static func parseCatalog(_ json: String) throws -> Catalog {
        guard let root = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let rawRuntimes = root["runtimes"] as? [[String: Any]],
              let rawTypes = root["devicetypes"] as? [[String: Any]]
        else { throw SimulatorError.unreadableOutput }

        let runtimes = rawRuntimes.compactMap { item -> Runtime? in
            guard item["isAvailable"] as? Bool ?? true,
                  let id = item["identifier"] as? String,
                  let name = item["name"] as? String
            else { return nil }
            let supported = (item["supportedDeviceTypes"] as? [[String: Any]] ?? [])
                .compactMap { $0["identifier"] as? String }
            return Runtime(
                id: id,
                name: name,
                platform: item["platform"] as? String ?? name.components(separatedBy: " ").first ?? name,
                version: item["version"] as? String ?? "",
                deviceTypeIDs: supported
            )
        }
        .sorted {
            if $0.platform != $1.platform { return platformOrder($0.platform) < platformOrder($1.platform) }
            return $0.version.compare($1.version, options: .numeric) == .orderedDescending
        }

        let types = rawTypes.compactMap { item -> DeviceType? in
            guard let id = item["identifier"] as? String, let name = item["name"] as? String else { return nil }
            return DeviceType(id: id, name: name, family: DeviceFamily(simulatorTypeIdentifier: id))
        }
        return Catalog(runtimes: runtimes, deviceTypes: types)
    }

    private static func platformOrder(_ platform: String) -> Int {
        ["iOS", "watchOS", "tvOS", "visionOS", "xrOS"].firstIndex(of: platform) ?? 9
    }

    func create(_ request: CreateRequest) async throws -> String {
        let name = request.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw SimulatorError.invalidName }
        let result = try await simctl(["create", name, request.deviceTypeID, request.runtimeID], timeout: 120)
        try check(result, "Creating the simulator")
        let udid = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !udid.isEmpty else { throw SimulatorError.unreadableOutput }
        return udid
    }

    func downloadRuntime(platform: String, onLine: @escaping @Sendable (String) -> Void) async throws {
        let code = try await runner.runStreaming(
            "/usr/bin/xcodebuild", ["-downloadPlatform", platform], timeout: 7_200, onLine: onLine
        )
        guard code == 0 else {
            throw SimulatorError.failed("Downloading the \(platform) runtime", "xcodebuild exit \(code)")
        }
    }

    // MARK: Plumbing

    private func simctl(_ arguments: [String], timeout: TimeInterval = 30) async throws -> CommandResult {
        try await runner.run("/usr/bin/xcrun", ["simctl"] + arguments, timeout: timeout)
    }

    private func check(_ result: CommandResult, _ action: String) throws {
        guard result.succeeded else {
            throw SimulatorError.failed(action, result.standardError.trimmedOneLine)
        }
    }
}
