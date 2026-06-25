import Foundation

/// Locates the Android SDK and the tools the fleet needs. Shared by discovery and
/// lifecycle control so both agree on the same `emulator`/`adb` binaries.
struct AndroidSDK {
    let root: URL

    var emulatorPath: String { root.appendingPathComponent("emulator/emulator").path }
    var adbPath: String { root.appendingPathComponent("platform-tools/adb").path }
    var sdkmanagerPath: String { root.appendingPathComponent("cmdline-tools/latest/bin/sdkmanager").path }
    var avdmanagerPath: String { root.appendingPathComponent("cmdline-tools/latest/bin/avdmanager").path }

    var hasEmulator: Bool { FileManager.default.isExecutableFile(atPath: emulatorPath) }
    var hasADB: Bool { FileManager.default.isExecutableFile(atPath: adbPath) }
    var hasSdkmanager: Bool { FileManager.default.isExecutableFile(atPath: sdkmanagerPath) }
    var hasAvdmanager: Bool { FileManager.default.isExecutableFile(atPath: avdmanagerPath) }

    /// The default install location used when no SDK is configured yet — also where the
    /// provisioner bootstraps the command-line tools.
    static var defaultRoot: URL {
        URL(fileURLWithPath: NSHomeDirectory() + "/Library/Android/sdk")
    }

    static func locate() -> AndroidSDK? {
        let environment = ProcessInfo.processInfo.environment
        let candidates = [
            environment["ANDROID_HOME"],
            environment["ANDROID_SDK_ROOT"],
            NSHomeDirectory() + "/Library/Android/sdk"
        ].compactMap { $0 }.map(URL.init(fileURLWithPath:))

        return candidates
            .first { FileManager.default.fileExists(atPath: $0.path) }
            .map(AndroidSDK.init(root:))
    }

    /// Like `locate()`, but never nil: falls back to the default root so the provisioner
    /// has somewhere to install into even on a machine with no SDK yet.
    static func locateOrDefault() -> AndroidSDK {
        locate() ?? AndroidSDK(root: defaultRoot)
    }

    /// `sdkmanager`/`avdmanager` are Java programs. A GUI app launched from Finder has no
    /// JAVA_HOME/PATH for a JDK, so resolve one — preferring an existing JAVA_HOME, then
    /// Android Studio's bundled JBR, then any system JVM.
    static func javaHome() -> String? {
        if let env = ProcessInfo.processInfo.environment["JAVA_HOME"],
           FileManager.default.fileExists(atPath: env + "/bin/java") {
            return env
        }
        let candidates = [
            "/Applications/Android Studio.app/Contents/jbr/Contents/Home",
            NSHomeDirectory() + "/Applications/Android Studio.app/Contents/jbr/Contents/Home",
        ]
        if let bundled = candidates.first(where: {
            FileManager.default.fileExists(atPath: $0 + "/bin/java")
        }) {
            return bundled
        }

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/libexec/java_home")
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let path = String(
                data: output.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let path, FileManager.default.fileExists(atPath: path + "/bin/java") else {
                return nil
            }
            return path
        } catch {
            return nil
        }
    }

    /// Environment overlay for running the command-line tools: a resolved JAVA_HOME (with
    /// its bin on PATH) plus the SDK root, so child tools find both Java and each other.
    func toolEnvironment() -> [String: String] {
        var overrides: [String: String] = [
            "ANDROID_SDK_ROOT": root.path,
            "ANDROID_HOME": root.path,
        ]
        if let java = AndroidSDK.javaHome() {
            overrides["JAVA_HOME"] = java
            let existingPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
            overrides["PATH"] = java + "/bin:" + existingPath
        }
        return overrides
    }
}
