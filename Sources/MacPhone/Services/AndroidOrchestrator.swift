import Foundation

struct AndroidOrchestrator {
    private let runner = CommandRunner()

    func discover() async -> DiscoveryResult {
        var devices: [MobileDevice] = []
        var issues: [DiscoveryIssue] = []

        guard let sdk = AndroidSDK.locate() else {
            return DiscoveryResult(
                devices: [],
                issues: [
                    DiscoveryIssue(
                        severity: .warning,
                        message: "Android SDK not found. Set ANDROID_HOME or install Android Studio."
                    )
                ]
            )
        }

        let emulator = sdk.emulatorPath
        let adb = sdk.adbPath

        var avds: [MobileDevice] = []
        if FileManager.default.isExecutableFile(atPath: emulator) {
            do {
                let result = try await runner.run(emulator, ["-list-avds"])
                if result.succeeded {
                    avds = parseAVDs(result.standardOutput)
                } else {
                    issues.append(DiscoveryIssue(severity: .warning, message: "Could not list Android AVDs: \(result.standardError.trimmedOneLine)"))
                }
            } catch {
                issues.append(DiscoveryIssue(severity: .warning, message: "Could not launch Android emulator tool."))
            }
        } else {
            issues.append(DiscoveryIssue(severity: .warning, message: "Android emulator binary missing at \(emulator)."))
        }

        var adbDevices: [MobileDevice] = []
        if FileManager.default.isExecutableFile(atPath: adb) {
            do {
                let result = try await runner.run(adb, ["devices", "-l"])
                if result.succeeded {
                    adbDevices = parseADBDevices(result.standardOutput)
                } else {
                    issues.append(DiscoveryIssue(severity: .warning, message: "Could not list adb devices: \(result.standardError.trimmedOneLine)"))
                }
            } catch {
                issues.append(DiscoveryIssue(severity: .warning, message: "Could not launch adb."))
            }
        } else {
            issues.append(DiscoveryIssue(severity: .warning, message: "adb missing at \(adb)."))
        }

        devices = await mergeDevices(avds: avds, adbDevices: adbDevices, adb: adb)
        return DiscoveryResult(devices: devices, issues: issues)
    }

    /// A running AVD appears twice: once in `emulator -list-avds` (offline definition)
    /// and once in `adb devices` (as `emulator-5554`). Resolve each running emulator's
    /// AVD name via `adb -s <id> emu avd name` and fold it into the matching AVD entry
    /// instead of listing both.
    private func mergeDevices(avds: [MobileDevice], adbDevices: [MobileDevice], adb: String) async -> [MobileDevice] {
        var byAVDName: [String: MobileDevice] = [:]
        for avd in avds { byAVDName[avd.name] = avd }

        var standalone: [MobileDevice] = []

        for device in adbDevices {
            if device.identifier.hasPrefix("emulator-"),
               let avdName = await runningAVDName(adb: adb, serial: device.identifier),
               let avd = byAVDName[avdName] {
                byAVDName[avdName] = MobileDevice(
                    id: avd.id,
                    name: avd.name,
                    platform: .android,
                    runtime: "AVD",
                    state: "Running (\(device.identifier))",
                    identifier: device.identifier
                )
            } else {
                standalone.append(device)
            }
        }

        return Array(byAVDName.values) + standalone
    }

    private func runningAVDName(adb: String, serial: String) async -> String? {
        guard let result = try? await runner.run(adb, ["-s", serial, "emu", "avd", "name"], timeout: 5),
              result.succeeded else { return nil }
        // Output is the AVD name on the first line, followed by an "OK" line.
        return result.standardOutput
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && $0 != "OK" }
    }

    private func parseAVDs(_ output: String) -> [MobileDevice] {
        output
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { name in
                MobileDevice(
                    id: "android-avd-\(name)",
                    name: name,
                    platform: .android,
                    runtime: "AVD",
                    state: "Available",
                    identifier: name
                )
            }
    }

    private func parseADBDevices(_ output: String) -> [MobileDevice] {
        output
            .split(whereSeparator: \.isNewline)
            .dropFirst()
            .compactMap { line -> MobileDevice? in
                let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
                guard parts.count >= 2 else { return nil }

                let identifier = parts[0]
                let state = parts[1]
                let model = parts.first { $0.hasPrefix("model:") }?.replacingOccurrences(of: "model:", with: "")
                let name = model?.replacingOccurrences(of: "_", with: " ") ?? identifier

                return MobileDevice(
                    id: "android-adb-\(identifier)",
                    name: name,
                    platform: .android,
                    runtime: "ADB",
                    state: state,
                    identifier: identifier
                )
            }
    }
}
