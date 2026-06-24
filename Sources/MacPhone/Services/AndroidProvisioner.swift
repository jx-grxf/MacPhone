import Foundation

/// Downloads an Android system image and creates a new AVD end-to-end, using only the
/// first-party command-line tools (`sdkmanager`/`avdmanager`). Streams progress so the UI
/// can show the live download. No Android Studio UI required.
struct AndroidProvisioner {
    private let runner = CommandRunner()

    struct Request: Equatable {
        var name: String
        var apiLevel: Int
        var tag: String          // "google_apis", "google_apis_playstore", "default"
        var abi: String          // "arm64-v8a" on Apple silicon
        var device: String       // avdmanager device profile, e.g. "pixel_7"

        /// sdkmanager package path for the system image.
        var systemImagePackage: String {
            "system-images;android-\(apiLevel);\(tag);\(abi)"
        }

        /// AVD names may not contain spaces or most punctuation.
        var sanitizedName: String {
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-."))
            let cleaned = name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
            return String(cleaned)
        }
    }

    enum ProvisionError: LocalizedError {
        case sdkRootMissing(String)
        case toolsMissing
        case javaMissing
        case licensesFailed(Int32)
        case packagesFailed([String], Int32)
        case imageFailed(Int32)
        case avdFailed(Int32)
        case nameTaken(String)

        var errorDescription: String? {
            switch self {
            case .sdkRootMissing(let path):
                "Android SDK folder not found at \(path). Install it or set ANDROID_HOME."
            case .toolsMissing:
                "Command-line tools (sdkmanager/avdmanager) not found. Install the Android "
                + "\"Command-line Tools (latest)\" package into your SDK, then retry."
            case .javaMissing:
                "No Java runtime found. Install Android Studio (it bundles one) or set JAVA_HOME."
            case .licensesFailed(let code):
                "Could not accept the SDK licenses (sdkmanager exit \(code)). "
                + "Open Android Studio → SDK Manager once to accept them, then retry."
            case .packagesFailed(let packages, let code):
                "Installing \(packages.joined(separator: ", ")) failed (sdkmanager exit \(code)). "
                + "The emulator may not boot without them."
            case .imageFailed(let code):
                "System image download failed (sdkmanager exit \(code))."
            case .avdFailed(let code):
                "Creating the AVD failed (avdmanager exit \(code))."
            case .nameTaken(let name):
                "An emulator named \"\(name)\" already exists. Pick another name."
            }
        }
    }

    /// Default profiles offered in the UI. ABI is fixed to arm64 on Apple silicon.
    static let deviceProfiles = ["pixel_7", "pixel_6", "pixel_5", "pixel_4", "Nexus 6"]
    static let apiLevels = [35, 34, 33, 31, 30]
    static let tags = ["google_apis", "google_apis_playstore", "default"]

    /// Runs the full flow, calling `onLog` for each progress line.
    func provision(_ request: Request, onLog: @escaping @Sendable (String) -> Void) async throws {
        let sdk = AndroidSDK.locateOrDefault()
        guard FileManager.default.fileExists(atPath: sdk.root.path) else {
            throw ProvisionError.sdkRootMissing(sdk.root.path)
        }
        guard sdk.hasSdkmanager, sdk.hasAvdmanager else {
            throw ProvisionError.toolsMissing
        }
        guard AndroidSDK.javaHome() != nil else {
            throw ProvisionError.javaMissing
        }
        let env = sdk.toolEnvironment()

        let name = request.sanitizedName
        if try await avdExists(named: name, sdk: sdk) {
            throw ProvisionError.nameTaken(name)
        }

        // 1) Accept licenses (idempotent). Feed a generous run of "y" for each prompt.
        // A non-zero exit means a license was left unaccepted — downstream installs would
        // then fail with a misleading "package not found", so stop here with a clear cause.
        onLog("Accepting SDK licenses…")
        let licenseInput = String(repeating: "y\n", count: 50)
        let licenseCode = try await runner.runStreaming(
            sdk.sdkmanagerPath, ["--licenses"], stdin: licenseInput, timeout: 120, environment: env, onLine: onLog
        )
        guard licenseCode == 0 else { throw ProvisionError.licensesFailed(licenseCode) }

        // 2) Make sure platform-tools + emulator are present so the AVD can actually boot.
        // Without them the AVD is created but cannot boot or be controlled via adb.
        onLog("Ensuring platform-tools and emulator are installed…")
        let toolsPackages = ["platform-tools", "emulator"]
        let toolsCode = try await runner.runStreaming(
            sdk.sdkmanagerPath, ["--install"] + toolsPackages,
            stdin: "y\n", timeout: 900, environment: env, onLine: onLog
        )
        guard toolsCode == 0 else { throw ProvisionError.packagesFailed(toolsPackages, toolsCode) }

        // 3) Download the system image (the big one).
        onLog("Downloading system image \(request.systemImagePackage)…")
        let imageCode = try await runner.runStreaming(
            sdk.sdkmanagerPath, ["--install", request.systemImagePackage],
            stdin: "y\n", timeout: 1800, environment: env, onLine: onLog
        )
        guard imageCode == 0 else { throw ProvisionError.imageFailed(imageCode) }

        // 4) Create the AVD. Answer "no" to the custom-hardware-profile prompt.
        onLog("Creating emulator \"\(name)\"…")
        let createCode = try await runner.runStreaming(
            sdk.avdmanagerPath,
            ["create", "avd", "-n", name, "-k", request.systemImagePackage, "-d", request.device, "--force"],
            stdin: "no\n", timeout: 120, environment: env, onLine: onLog
        )
        guard createCode == 0 else { throw ProvisionError.avdFailed(createCode) }

        onLog("Done. Emulator \"\(name)\" is ready to boot.")
    }

    private func avdExists(named name: String, sdk: AndroidSDK) async throws -> Bool {
        guard sdk.hasEmulator else { return false }
        let result = try await runner.run(sdk.emulatorPath, ["-list-avds"], timeout: 20, environment: sdk.toolEnvironment())
        return result.standardOutput
            .split(whereSeparator: \.isNewline)
            .contains { $0.trimmingCharacters(in: .whitespaces) == name }
    }
}
