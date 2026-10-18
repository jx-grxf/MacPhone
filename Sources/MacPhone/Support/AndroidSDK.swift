import Foundation

/// Finds the Android SDK and its tools. A Mac app started from Finder does not see the
/// shell environment, so besides ANDROID_HOME this checks the Android Studio default, the
/// Homebrew `android-commandlinetools` layout and a folder chosen in Settings.
struct AndroidSDK: Sendable {
    static let customRootKey = "android.sdkRoot"

    let root: URL

    var emulatorPath: String { root.appendingPathComponent("emulator/emulator").path }
    var sdkmanagerPath: String { root.appendingPathComponent("cmdline-tools/latest/bin/sdkmanager").path }
    var avdmanagerPath: String { root.appendingPathComponent("cmdline-tools/latest/bin/avdmanager").path }

    /// Homebrew's `android-platform-tools` cask puts adb on PATH, outside any SDK root.
    var adbPath: String {
        let bundled = root.appendingPathComponent("platform-tools/adb").path
        if FileManager.default.isExecutableFile(atPath: bundled) { return bundled }
        return Self.homebrewADB ?? bundled
    }

    var hasEmulator: Bool { FileManager.default.isExecutableFile(atPath: emulatorPath) }
    var hasADB: Bool { FileManager.default.isExecutableFile(atPath: adbPath) }
    var hasSdkmanager: Bool { FileManager.default.isExecutableFile(atPath: sdkmanagerPath) }
    var hasAvdmanager: Bool { FileManager.default.isExecutableFile(atPath: avdmanagerPath) }

    static var defaultRoot: URL {
        URL(fileURLWithPath: NSHomeDirectory() + "/Library/Android/sdk")
    }

    private static var homebrewADB: String? {
        ["/opt/homebrew/bin/adb", "/usr/local/bin/adb"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func candidateRoots() -> [URL] {
        let environment = ProcessInfo.processInfo.environment
        return [
            UserDefaults.standard.string(forKey: customRootKey),
            environment["ANDROID_HOME"],
            environment["ANDROID_SDK_ROOT"],
            NSHomeDirectory() + "/Library/Android/sdk",
            "/opt/homebrew/share/android-commandlinetools",
            "/usr/local/share/android-commandlinetools",
        ]
        .compactMap { $0?.isEmpty == false ? $0 : nil }
        .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
    }

    /// The first candidate that actually contains tools. An empty leftover folder (a stale
    /// ANDROID_HOME) must not hide a working SDK further down the list.
    static func locate() -> AndroidSDK? {
        let fm = FileManager.default
        let existing = candidateRoots().filter { fm.fileExists(atPath: $0.path) }.map(AndroidSDK.init(root:))
        return existing.first { $0.hasEmulator }
            ?? existing.first { $0.hasSdkmanager }
            ?? existing.first
    }

    static func locateOrDefault() -> AndroidSDK {
        locate() ?? AndroidSDK(root: defaultRoot)
    }

    /// Where AVDs live, following the emulator's own lookup order.
    static var avdHome: URL {
        let environment = ProcessInfo.processInfo.environment
        if let home = environment["ANDROID_AVD_HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home)
        }
        if let user = environment["ANDROID_USER_HOME"], !user.isEmpty {
            return URL(fileURLWithPath: user).appendingPathComponent("avd")
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".android/avd")
    }

    /// The `<name>.avd` folder, read from `<name>.ini` so relocated AVDs resolve too.
    static func avdDirectory(named name: String) -> URL {
        let ini = avdHome.appendingPathComponent("\(name).ini")
        if let contents = try? String(contentsOf: ini, encoding: .utf8),
           let line = contents.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("path=") }) {
            return URL(fileURLWithPath: String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
        }
        return avdHome.appendingPathComponent("\(name).avd", isDirectory: true)
    }

    /// sdkmanager and avdmanager are Java programs, and a Finder-launched app has no
    /// JAVA_HOME. Prefer an explicit one, then Android Studio's bundled runtime, then any JDK.
    static func javaHome() async -> String? {
        if let cached = JavaHomeCache.shared.value { return cached }
        let fm = FileManager.default
        var resolved: String?
        if let env = ProcessInfo.processInfo.environment["JAVA_HOME"], fm.fileExists(atPath: env + "/bin/java") {
            resolved = env
        } else if let studio = [
            "/Applications/Android Studio.app/Contents/jbr/Contents/Home",
            NSHomeDirectory() + "/Applications/Android Studio.app/Contents/jbr/Contents/Home",
        ].first(where: { fm.fileExists(atPath: $0 + "/bin/java") }) {
            resolved = studio
        } else if let result = try? await CommandRunner().run("/usr/libexec/java_home", timeout: 10),
                  result.succeeded {
            let path = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            if fm.fileExists(atPath: path + "/bin/java") { resolved = path }
        }
        if let resolved { JavaHomeCache.shared.value = resolved }
        return resolved
    }

    func toolEnvironment() async -> [String: String] {
        var overrides = ["ANDROID_SDK_ROOT": root.path, "ANDROID_HOME": root.path]
        if let java = await Self.javaHome() {
            overrides["JAVA_HOME"] = java
            overrides["PATH"] = java + "/bin:" + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")
        }
        return overrides
    }
}

private final class JavaHomeCache: @unchecked Sendable {
    static let shared = JavaHomeCache()
    private let lock = NSLock()
    private var stored: String?

    var value: String? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
