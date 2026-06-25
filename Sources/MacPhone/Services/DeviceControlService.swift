import Foundation

/// Boots and stops fleet members through first-party tooling only:
/// iOS via `xcrun simctl`, Android via the official `emulator`/`adb` binaries.
struct DeviceControlService {
    private let runner = CommandRunner()

    enum ControlError: LocalizedError {
        case androidSDKMissing
        case toolMissing(String)
        case commandFailed(String)
        case unsupported

        var errorDescription: String? {
            switch self {
            case .androidSDKMissing: "Android SDK not found. Set ANDROID_HOME or install Android Studio."
            case .toolMissing(let tool): "Required tool missing: \(tool)."
            case .commandFailed(let message): message
            case .unsupported: "This action is not supported for the selected device."
            }
        }
    }

    // MARK: Boot

    func boot(_ device: MobileDevice, headless: Bool = false, coldBoot: Bool = false) async throws {
        switch device.platform {
        case .ios: try await bootSimulator(udid: device.identifier)
        case .android: try await bootEmulator(avdName: device.identifier, headless: headless, coldBoot: coldBoot)
        }
    }

    /// Erase the device back to a clean state. iOS simulators must be shut down first;
    /// Android wipes on the next cold boot.
    func wipe(_ device: MobileDevice) async throws {
        switch device.platform {
        case .ios:
            // `simctl erase` fails on a booted device, so shut it down first (ignoring the
            // benign "already shutdown" case).
            if device.isRunning {
                try await shutdownSimulator(udid: device.identifier)
            }
            let result = try await runner.run("/usr/bin/xcrun", ["simctl", "erase", device.identifier], timeout: 60)
            if !result.succeeded {
                throw ControlError.commandFailed("simctl erase failed: \(result.standardError.trimmedOneLine)")
            }
        case .android:
            // A running AVD can't be wiped in place; relaunch it cold with -wipe-data.
            guard let sdk = AndroidSDK.locate() else { throw ControlError.androidSDKMissing }
            guard sdk.hasEmulator else { throw ControlError.toolMissing("emulator") }
            if device.isRunning { try await killEmulator(serial: device.identifier) }
            let avdName = avdNameForWipe(device)
            try AndroidAVDPerformance.apply(toAVDNamed: avdName)
            try await runner.launchDetached(
                sdk.emulatorPath,
                ["-avd", avdName, "-wipe-data", "-accel", "auto", "-gpu", "host", "-no-boot-anim"]
            )
        }
    }

    private func avdNameForWipe(_ device: MobileDevice) -> String {
        // For a stopped AVD the identifier is the AVD name; for a running one it's the
        // serial, so fall back to the display name.
        device.identifier.hasPrefix("emulator-") ? device.name : device.identifier
    }

    // MARK: Stop

    func stop(_ device: MobileDevice) async throws {
        switch device.platform {
        case .ios: try await shutdownSimulator(udid: device.identifier)
        case .android: try await killEmulator(serial: device.identifier)
        }
    }

    // MARK: iOS

    private func bootSimulator(udid: String) async throws {
        let result = try await runner.run("/usr/bin/xcrun", ["simctl", "boot", udid], timeout: 30)
        // `Unable to boot device in current state: Booted` is benign.
        if !result.succeeded, !result.standardError.localizedCaseInsensitiveContains("current state: booted") {
            throw ControlError.commandFailed("simctl boot failed: \(result.standardError.trimmedOneLine)")
        }
        // Bring the Simulator UI forward so the booted device is visible.
        _ = try? await runner.run("/usr/bin/open", ["-a", "Simulator"], timeout: 15)
    }

    private func shutdownSimulator(udid: String) async throws {
        let result = try await runner.run("/usr/bin/xcrun", ["simctl", "shutdown", udid], timeout: 30)
        if !result.succeeded, !result.standardError.localizedCaseInsensitiveContains("current state: shutdown") {
            throw ControlError.commandFailed("simctl shutdown failed: \(result.standardError.trimmedOneLine)")
        }
    }

    // MARK: Android

    private func bootEmulator(avdName: String, headless: Bool, coldBoot: Bool) async throws {
        guard let sdk = AndroidSDK.locate() else { throw ControlError.androidSDKMissing }
        guard sdk.hasEmulator else { throw ControlError.toolMissing("emulator") }
        try AndroidAVDPerformance.apply(toAVDNamed: avdName)
        // `-accel auto` prefers Hypervisor.framework while permitting a fallback.
        // GPU is pinned explicitly: with a window we force `host` so rendering goes
        // through the host Metal GPU (ANGLE). `-gpu auto` is unreliable on Apple
        // silicon — it silently falls back to SwiftShader (software Vulkan), which
        // pegs the CPU and makes the whole VM crawl. Headless has no host surface,
        // so it must use the software path explicitly.
        let gpu = headless ? "swiftshader_indirect" : "host"
        var args = ["-avd", avdName, "-accel", "auto", "-gpu", gpu, "-no-boot-anim"]
        if headless { args.append("-no-window") }
        if coldBoot { args.append("-no-snapshot-load") }
        // The emulator process stays alive for the lifetime of the device; launch detached.
        try await runner.launchDetached(sdk.emulatorPath, args)
    }

    private func killEmulator(serial: String) async throws {
        guard let sdk = AndroidSDK.locate() else { throw ControlError.androidSDKMissing }
        guard sdk.hasADB else { throw ControlError.toolMissing("adb") }
        let result = try await runner.run(sdk.adbPath, ["-s", serial, "emu", "kill"], timeout: 15)
        if !result.succeeded {
            throw ControlError.commandFailed("adb emu kill failed: \(result.standardError.trimmedOneLine)")
        }
    }

    // MARK: Boot detection (for the one-click provision flow)

    /// Online `emulator-*` serials reported by `adb devices`. Used to spot the
    /// serial a freshly launched emulator attaches as.
    func emulatorSerials() async -> [String] {
        guard let sdk = AndroidSDK.locate(), sdk.hasADB else { return [] }
        guard let result = try? await runner.run(sdk.adbPath, ["devices"], timeout: 15),
              result.succeeded else { return [] }
        return result.standardOutput
            .split(whereSeparator: \.isNewline)
            .dropFirst()
            .compactMap { line in
                let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
                guard parts.count >= 2, parts[0].hasPrefix("emulator-"), parts[1] == "device" else { return nil }
                return parts[0]
            }
    }

    /// Wait until a *new* emulator (not in `existing`) comes online, then return its
    /// serial. Polls `adb devices`; throws on timeout.
    func waitForNewEmulator(excluding existing: Set<String>, timeout: TimeInterval = 150) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let current = await emulatorSerials()
            if let fresh = current.first(where: { !existing.contains($0) }) {
                return fresh
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        throw ControlError.commandFailed("Timed out waiting for the emulator to come online.")
    }

    /// Poll `getprop sys.boot_completed` until the emulator finishes booting.
    func waitForBootCompleted(serial: String, timeout: TimeInterval = 240) async throws {
        guard let sdk = AndroidSDK.locate() else { throw ControlError.androidSDKMissing }
        guard sdk.hasADB else { throw ControlError.toolMissing("adb") }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let result = try? await runner.run(
                sdk.adbPath, ["-s", serial, "shell", "getprop", "sys.boot_completed"],
                timeout: 15, environment: sdk.toolEnvironment()
            ), result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) == "1" {
                return
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
        throw ControlError.commandFailed("Timed out waiting for the emulator to finish booting.")
    }
}
