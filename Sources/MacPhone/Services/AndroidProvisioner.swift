import Foundation

/// Downloads a system image and creates an AVD with `sdkmanager` and `avdmanager`.
struct AndroidProvisioner: Sendable {
    private let runner = CommandRunner()

    struct Request: Equatable, Sendable {
        var name: String
        /// sdkmanager platform segment: "37.0", "36", "35".
        var platform: String
        var tag: String
        var device: String

        var systemImagePackage: String {
            "system-images;android-\(platform);\(tag);arm64-v8a"
        }

        var sanitizedName: String {
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-."))
            return String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        }
    }

    struct Platform: Identifiable, Hashable, Sendable {
        let id: String
        let title: String
    }

    /// Current arm64 images on Google's repository (checked 2026-10-18).
    static let platforms = [
        Platform(id: "37.0", title: "Android 17 (API 37)"),
        Platform(id: "36", title: "Android 16 (API 36)"),
        Platform(id: "35", title: "Android 15 (API 35)"),
        Platform(id: "34", title: "Android 14 (API 34)"),
    ]
    static let deviceProfiles = ["pixel_9", "pixel_8", "pixel_7", "pixel_tablet", "pixel_fold"]
    static let tags = [
        ("google_apis_playstore", "Google Play"),
        ("google_apis", "Google APIs"),
    ]

    enum ProvisionError: LocalizedError {
        case toolsMissing
        case javaMissing
        case nameTaken(String)
        case step(String, Int32)

        var errorDescription: String? {
            switch self {
            case .toolsMissing:
                "The Android command-line tools are missing. Install them in Setup first."
            case .javaMissing:
                "No Java runtime found. Install Android Studio (it brings one) or a JDK."
            case .nameTaken(let name):
                "An emulator named \"\(name)\" already exists."
            case .step(let step, let code):
                "\(step) failed (exit \(code))."
            }
        }
    }

    func provision(_ request: Request, onLog: @escaping @Sendable (String) -> Void) async throws {
        let sdk = AndroidSDK.locateOrDefault()
        guard sdk.hasSdkmanager, sdk.hasAvdmanager else { throw ProvisionError.toolsMissing }
        guard await AndroidSDK.javaHome() != nil else { throw ProvisionError.javaMissing }
        let env = await sdk.toolEnvironment()

        let name = request.sanitizedName
        if FileManager.default.fileExists(atPath: AndroidSDK.avdHome.appendingPathComponent("\(name).ini").path) {
            throw ProvisionError.nameTaken(name)
        }

        onLog("Accepting SDK licenses…")
        let licenses = try await runner.runStreaming(
            sdk.sdkmanagerPath, ["--licenses"], stdin: String(repeating: "y\n", count: 50),
            timeout: 120, environment: env, onLine: onLog
        )
        guard licenses == 0 else { throw ProvisionError.step("Accepting the licenses", licenses) }

        onLog("Installing platform-tools and the emulator…")
        let tools = try await runner.runStreaming(
            sdk.sdkmanagerPath, ["--install", "platform-tools", "emulator"],
            stdin: "y\n", timeout: 900, environment: env, onLine: onLog
        )
        guard tools == 0 else { throw ProvisionError.step("Installing platform-tools and the emulator", tools) }

        onLog("Downloading \(request.systemImagePackage)…")
        let image = try await runner.runStreaming(
            sdk.sdkmanagerPath, ["--install", request.systemImagePackage],
            stdin: "y\n", timeout: 3600, environment: env, onLine: onLog
        )
        guard image == 0 else { throw ProvisionError.step("Downloading the system image", image) }

        onLog("Creating \(name)…")
        let create = try await runner.runStreaming(
            sdk.avdmanagerPath,
            ["create", "avd", "-n", name, "-k", request.systemImagePackage, "-d", request.device],
            stdin: "no\n", timeout: 120, environment: env, onLine: onLog
        )
        guard create == 0 else { throw ProvisionError.step("Creating the AVD", create) }

        AndroidAVDPerformance.markManaged(name)
        try? AndroidAVDPerformance.apply(toAVDNamed: name)
        onLog("\(name) is ready.")
    }
}
