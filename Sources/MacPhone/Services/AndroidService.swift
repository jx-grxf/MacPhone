import Foundation

/// Android emulators and adb devices, through the official `emulator` and `adb` binaries.
struct AndroidService: Sendable {
    private let runner = CommandRunner()

    enum AndroidError: LocalizedError {
        case sdkMissing
        case toolMissing(String)
        case notRunning
        case failed(String, String)

        var errorDescription: String? {
            switch self {
            case .sdkMissing:
                "No Android SDK found. Open Setup to install it or pick its folder in Settings."
            case .toolMissing(let tool):
                "\(tool) is not installed. Open Setup to install it."
            case .notRunning:
                "Start the emulator first."
            case .failed(let action, let detail):
                detail.isEmpty ? "\(action) failed." : "\(action) failed: \(detail)"
            }
        }
    }

    static var logDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/MacPhone", isDirectory: true)
    }

    // MARK: Discovery

    func discover() async -> DiscoveryResult {
        guard let sdk = AndroidSDK.locate() else {
            return DiscoveryResult(devices: [], issues: [
                DiscoveryIssue(severity: .warning, message: "No Android SDK found. Open Setup to install one.")
            ])
        }

        var issues: [DiscoveryIssue] = []
        var avdNames: [String] = []
        if sdk.hasEmulator {
            if let result = try? await runner.run(sdk.emulatorPath, ["-list-avds"]), result.succeeded {
                avdNames = Self.parseAVDList(result.standardOutput)
            } else {
                issues.append(DiscoveryIssue(severity: .warning, message: "The emulator could not list its AVDs."))
            }
        } else {
            issues.append(DiscoveryIssue(severity: .warning, message: "The Android emulator is not installed. Open Setup to add it."))
        }

        var online: [ADBDevice] = []
        if sdk.hasADB {
            if let result = try? await runner.run(sdk.adbPath, ["devices", "-l"], timeout: 15), result.succeeded {
                online = Self.parseADBDevices(result.standardOutput)
            } else {
                issues.append(DiscoveryIssue(severity: .warning, message: "adb did not answer."))
            }
        }

        var runningAVD: [String: ADBDevice] = [:]
        var foreign: [ADBDevice] = []
        for device in online {
            if device.serial.hasPrefix("emulator-"),
               let name = await avdName(adb: sdk.adbPath, serial: device.serial),
               avdNames.contains(name) {
                runningAVD[name] = device
            } else {
                foreign.append(device)
            }
        }

        // An emulator shows up in adb only some seconds after launch, and is "device" long
        // before Android has finished booting. Count both phases as starting.
        let launched = await launchedAVDs()
        var avds: [MobileDevice] = []
        for name in avdNames {
            let live = runningAVD[name]
            var state: DeviceState = launched.contains(name) ? .booting : .shutdown
            if let live, live.state == "device" {
                state = await bootCompleted(adb: sdk.adbPath, serial: live.serial) ? .booted : .booting
            }
            avds.append(MobileDevice(
                id: "avd-\(name)",
                name: name.replacingOccurrences(of: "_", with: " "),
                kind: .avd,
                family: .android,
                osVersion: Self.androidVersion(ofAVD: name),
                state: state,
                identifier: name,
                serial: live?.serial
            ))
        }
        let others = foreign.map { device in
            MobileDevice(
                id: "adb-\(device.serial)",
                name: device.model ?? device.serial,
                kind: .adbOnly,
                family: .android,
                osVersion: "Android",
                state: device.state == "device" ? .booted : .unavailable(device.state),
                identifier: device.serial,
                serial: device.serial
            )
        }
        return DiscoveryResult(devices: avds + others, issues: issues)
    }

    struct ADBDevice: Equatable {
        let serial: String
        let state: String
        let model: String?
    }

    static func parseAVDList(_ output: String) -> [String] {
        output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("INFO") && !$0.contains(" ") }
    }

    static func parseADBDevices(_ output: String) -> [ADBDevice] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard parts.count >= 2, !line.hasPrefix("List of devices"), !line.hasPrefix("*") else { return nil }
            let model = parts.first { $0.hasPrefix("model:") }
                .map { String($0.dropFirst(6)).replacingOccurrences(of: "_", with: " ") }
            return ADBDevice(serial: parts[0], state: parts[1], model: model)
        }
    }

    /// "Android 15" from the AVD's system image path (`system-images/android-35/...`).
    static func androidVersion(ofAVD name: String) -> String {
        let config = AndroidSDK.avdDirectory(named: name).appendingPathComponent("config.ini")
        guard let contents = try? String(contentsOf: config, encoding: .utf8),
              let line = contents.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("image.sysdir.1=") }),
              let range = line.range(of: #"android-(\d+)"#, options: .regularExpression),
              let api = Int(line[range].dropFirst(8))
        else { return "Android" }
        return AndroidAPI.versionName(api).map { "Android \($0) · API \(api)" } ?? "Android API \(api)"
    }

    /// AVD names of running emulator processes, from their `-avd <name>` argument.
    private func launchedAVDs() async -> Set<String> {
        guard let result = try? await runner.run("/bin/ps", ["-axo", "command"], timeout: 5) else { return [] }
        return Self.parseLaunchedAVDs(result.standardOutput)
    }

    static func parseLaunchedAVDs(_ psOutput: String) -> Set<String> {
        var names = Set<String>()
        for line in psOutput.split(whereSeparator: \.isNewline) where line.contains("qemu-system") || line.contains("/emulator ") {
            let parts = line.split(separator: " ")
            if let index = parts.firstIndex(of: "-avd"), index + 1 < parts.count {
                names.insert(String(parts[index + 1]))
            }
        }
        return names
    }

    private func bootCompleted(adb: String, serial: String) async -> Bool {
        let result = try? await runner.run(adb, ["-s", serial, "shell", "getprop", "sys.boot_completed"], timeout: 5)
        return result?.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }

    private func avdName(adb: String, serial: String) async -> String? {
        guard let result = try? await runner.run(adb, ["-s", serial, "emu", "avd", "name"], timeout: 5),
              result.succeeded else { return nil }
        return result.standardOutput
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && $0 != "OK" }
    }

    // MARK: Lifecycle

    struct BootOptions: Sendable {
        var withoutWindow = false
        var coldBoot = false
        var wipeData = false
    }

    func boot(avd name: String, options: BootOptions = BootOptions()) async throws {
        let sdk = try requireSDK()
        guard sdk.hasEmulator else { throw AndroidError.toolMissing("The Android emulator") }
        AndroidAVDPerformance.applyIfManaged(toAVDNamed: name)

        // Without a window there is no host surface, so the GPU has to be software.
        var arguments = ["-avd", name, "-accel", "auto", "-gpu", options.withoutWindow ? "swiftshader_indirect" : "host", "-no-boot-anim"]
        if options.withoutWindow { arguments.append("-no-window") }
        if options.coldBoot || options.wipeData { arguments.append("-no-snapshot-load") }
        if options.wipeData { arguments.append("-wipe-data") }

        let log = Self.logDirectory.appendingPathComponent("emulator-\(name).log")
        try await runner.launchDetached(sdk.emulatorPath, arguments, logFile: log)
    }

    func stop(serial: String) async throws {
        let sdk = try requireSDK()
        guard sdk.hasADB else { throw AndroidError.toolMissing("adb") }
        let result = try await runner.run(sdk.adbPath, ["-s", serial, "emu", "kill"], timeout: 15)
        guard result.succeeded else {
            throw AndroidError.failed("Stopping the emulator", result.standardError.trimmedOneLine)
        }
        try await waitUntilOffline(serial: serial, adb: sdk.adbPath)
    }

    /// `emu kill` returns before the emulator has released the AVD lock. Booting again
    /// in that window fails with "another emulator instance is running".
    private func waitUntilOffline(serial: String, adb: String) async throws {
        for _ in 0..<40 {
            let result = try? await runner.run(adb, ["devices"], timeout: 5)
            let serials = Self.parseADBDevices(result?.standardOutput ?? "").map(\.serial)
            if !serials.contains(serial) {
                try await Task.sleep(for: .seconds(1))
                return
            }
            try await Task.sleep(for: .milliseconds(500))
        }
    }

    func wipe(avd name: String, runningSerial: String?, options: BootOptions) async throws {
        if let runningSerial { try await stop(serial: runningSerial) }
        var wipe = options
        wipe.wipeData = true
        try await boot(avd: name, options: wipe)
    }

    func delete(avd name: String, runningSerial: String?) async throws {
        if let runningSerial { try await stop(serial: runningSerial) }
        let fm = FileManager.default
        let directory = AndroidSDK.avdDirectory(named: name)
        let ini = AndroidSDK.avdHome.appendingPathComponent("\(name).ini")
        do {
            if fm.fileExists(atPath: directory.path) { try fm.removeItem(at: directory) }
            if fm.fileExists(atPath: ini.path) { try fm.removeItem(at: ini) }
        } catch {
            throw AndroidError.failed("Deleting the emulator", error.localizedDescription)
        }
        AndroidAVDPerformance.forget(name)
    }

    // MARK: Testing helpers

    func install(_ apk: URL, serial: String) async throws {
        try await adb(serial, ["install", "-r", "-t", apk.path], timeout: 300, action: "Installing \(apk.lastPathComponent)")
    }

    func open(_ url: String, serial: String) async throws {
        try await adb(serial, ["shell", "am", "start", "-a", "android.intent.action.VIEW", "-d", url], action: "Opening the URL")
    }

    func screenshot(serial: String, to file: URL) async throws {
        let remote = "/sdcard/macphone-screenshot.png"
        try await adb(serial, ["shell", "screencap", "-p", remote], timeout: 30, action: "Taking the screenshot")
        try await adb(serial, ["pull", remote, file.path], timeout: 30, action: "Copying the screenshot")
        _ = try? await adb(serial, ["shell", "rm", remote], action: "Cleaning up")
    }

    func setAppearance(dark: Bool, serial: String) async throws {
        try await adb(serial, ["shell", "cmd", "uimode", "night", dark ? "yes" : "no"], action: "Changing the appearance")
    }

    // MARK: Plumbing

    private func requireSDK() throws -> AndroidSDK {
        guard let sdk = AndroidSDK.locate() else { throw AndroidError.sdkMissing }
        return sdk
    }

    @discardableResult
    private func adb(_ serial: String, _ arguments: [String], timeout: TimeInterval = 20, action: String) async throws -> CommandResult {
        let sdk = try requireSDK()
        guard sdk.hasADB else { throw AndroidError.toolMissing("adb") }
        let result = try await runner.run(sdk.adbPath, ["-s", serial] + arguments, timeout: timeout)
        let failureText = result.standardError.isEmpty ? result.standardOutput : result.standardError
        // `adb install` reports some failures on stdout with exit code 0.
        guard result.succeeded, !result.standardOutput.contains("Failure [") else {
            throw AndroidError.failed(action, failureText.trimmedOneLine)
        }
        return result
    }
}

enum AndroidAPI {
    static func versionName(_ api: Int) -> String? {
        switch api {
        case 37: "17"
        case 36: "16"
        case 35: "15"
        case 34: "14"
        case 33: "13"
        case 32, 31: "12"
        case 30: "11"
        case 29: "10"
        case 28: "9"
        default: nil
        }
    }
}
