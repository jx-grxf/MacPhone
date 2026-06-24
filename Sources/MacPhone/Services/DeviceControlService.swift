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
            try await runner.launchDetached(sdk.emulatorPath, ["-avd", avdNameForWipe(device), "-wipe-data", "-no-boot-anim"])
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
        // -gpu host uses the Mac's real GPU; without it the emulator falls back to
        // software rendering and the UI crawls.
        var args = ["-avd", avdName, "-gpu", "host"]
        if headless { args.append(contentsOf: ["-no-window", "-no-boot-anim"]) }
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
}
