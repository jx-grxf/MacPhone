import Foundation
import CryptoKit

struct Dependency: Identifiable, Equatable, Sendable {
    enum Group: String, CaseIterable, Sendable {
        case bridge = "Bluetooth bridge"
        case android = "Android"
        case apple = "Apple simulators"
    }

    let id: String
    let group: Group
    let title: String
    let detail: String
    let satisfied: Bool
    let required: Bool
    let fix: Fix

    enum Fix: Equatable, Sendable {
        case none
        case brewCask(String)
        case brewFormula(String)
        case sdkPackages([String])
        case commandLineTools
        case bridgeRuntime
        case simulatorRuntime(String)
        case link(URL)

        var label: String? {
            switch self {
            case .none: nil
            case .brewCask, .brewFormula, .sdkPackages, .commandLineTools: "Install"
            case .bridgeRuntime: "Install"
            case .simulatorRuntime: "Download"
            case .link: "Open"
            }
        }
    }
}

/// Checks the Mac for what MacPhone needs and installs missing pieces with Homebrew,
/// sdkmanager, xcodebuild or pip.
struct SetupService: Sendable {
    private let runner = CommandRunner()

    /// Pinned with its SHA-1 from Google's repository2-4.xml (checked 2026-10-18).
    private static let commandLineTools = (
        url: URL(string: "https://dl.google.com/android/repository/commandlinetools-mac-15641748_latest.zip")!,
        sha1: "b62a5d8cf63ded173b47be867be4ee058ceda6df"
    )

    static let minimumPython = (3, 11)

    enum SetupError: LocalizedError {
        case brewMissing
        case toolsMissing
        case javaMissing
        case bridgeScriptMissing
        case pythonMissing
        case downloadFailed(String)
        case checksumMismatch
        case commandFailed(String, Int32)

        var errorDescription: String? {
            switch self {
            case .brewMissing: "Homebrew is not installed."
            case .toolsMissing: "Install the Android command-line tools first."
            case .javaMissing: "No Java runtime found. Install Android Studio first; it brings one."
            case .bridgeScriptMissing: "The bridge script is missing from the app. Reinstall MacPhone."
            case .pythonMissing: "Python 3.11 or newer is needed. Install it with Homebrew."
            case .downloadFailed(let message): "Download failed: \(message)"
            case .checksumMismatch: "The downloaded tools did not match Google's checksum."
            case .commandFailed(let tool, let code): "\(tool) failed (exit \(code))."
            }
        }
    }

    // MARK: Checks

    func check() async -> [Dependency] {
        let sdk = AndroidSDK.locateOrDefault()
        let brew = Self.brewPath()
        let java = await AndroidSDK.javaHome()
        let python = await Self.python()
        let bridgeState = await Self.bridgeRuntimeState()
        let xcode = await SimulatorService.xcodeReady()
        let installedPlatforms = xcode ? await installedSimulatorPlatforms() : []

        var items: [Dependency] = []

        items.append(Dependency(
            id: "python", group: .bridge, title: "Python 3.11+",
            detail: python.map { "\($0.version) at \($0.path)" }
                ?? "Runs the bridge that publishes the device in the emulator.",
            satisfied: python != nil, required: true,
            fix: python != nil ? .none : (brew != nil ? .brewFormula("python") : .link(URL(string: "https://www.python.org/downloads/macos/")!))
        ))
        items.append(Dependency(
            id: "bridge", group: .bridge, title: "Bridge runtime (Bumble)",
            detail: bridgeState.detail,
            satisfied: bridgeState == .ready, required: true,
            fix: bridgeState == .ready || python == nil ? .none : .bridgeRuntime
        ))

        items.append(Dependency(
            id: "java", group: .android, title: "Java runtime",
            detail: java.map { "Found at \($0)" } ?? "sdkmanager and avdmanager need it. Android Studio brings one.",
            satisfied: java != nil, required: true,
            fix: java != nil ? .none : (brew != nil ? .brewCask("android-studio") : .link(URL(string: "https://developer.android.com/studio")!))
        ))
        items.append(Dependency(
            id: "cmdline-tools", group: .android, title: "Android command-line tools",
            detail: sdk.hasSdkmanager ? "In \(sdk.root.path)" : "Downloads system images and creates emulators.",
            satisfied: sdk.hasSdkmanager, required: true,
            fix: sdk.hasSdkmanager ? .none : .commandLineTools
        ))
        items.append(Dependency(
            id: "platform-tools", group: .android, title: "adb",
            detail: sdk.hasADB ? "At \(sdk.adbPath)" : "Talks to running emulators.",
            satisfied: sdk.hasADB, required: true,
            fix: sdk.hasADB ? .none : .sdkPackages(["platform-tools"])
        ))
        items.append(Dependency(
            id: "emulator", group: .android, title: "Android emulator",
            detail: sdk.hasEmulator ? "In \(sdk.root.path)" : "Runs the Android virtual devices. netsim comes with it.",
            satisfied: sdk.hasEmulator, required: true,
            fix: sdk.hasEmulator ? .none : .sdkPackages(["emulator"])
        ))

        items.append(Dependency(
            id: "xcode", group: .apple, title: "Xcode",
            detail: xcode ? "Installed and selected." : "Needed for simulators. Install it from the App Store and open it once.",
            satisfied: xcode, required: false,
            fix: xcode ? .none : .link(URL(string: "macappstore://apps.apple.com/app/xcode/id497799835")!)
        ))
        for platform in ["iOS", "watchOS", "tvOS", "visionOS"] where xcode {
            let installed = installedPlatforms.contains(platform)
            items.append(Dependency(
                id: "runtime-\(platform)", group: .apple, title: "\(platform) runtime",
                detail: installed ? "Installed." : "Several GB from Apple.",
                satisfied: installed, required: platform == "iOS",
                fix: installed ? .none : .simulatorRuntime(platform)
            ))
        }
        return items
    }

    static func brewPath() -> String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The newest Python 3.11+ on the machine. `/usr/bin/python3` is 3.9 and too old for
    /// current Bumble, which would make pip silently resolve an outdated release.
    static func python() async -> (path: String, version: String)? {
        let candidates = [
            "/opt/homebrew/bin/python3", "/usr/local/bin/python3",
            "/opt/homebrew/bin/python3.14", "/opt/homebrew/bin/python3.13", "/opt/homebrew/bin/python3.12",
            "/opt/homebrew/bin/python3.11", "/Library/Frameworks/Python.framework/Versions/Current/bin/python3",
            "/usr/bin/python3",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            guard let result = try? await CommandRunner().run(path, ["-c", "import sys; print('%d.%d' % sys.version_info[:2])"], timeout: 10),
                  result.succeeded else { continue }
            let version = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = version.split(separator: ".").compactMap { Int($0) }
            if parts.count == 2, (parts[0], parts[1]) >= minimumPython {
                return (path, "Python \(version)")
            }
        }
        return nil
    }

    enum BridgeRuntimeState: Equatable {
        case missing, outdated, broken, ready

        var detail: String {
            switch self {
            case .missing: "Not installed. Needed to show a device in the emulator."
            case .outdated: "Installed for an older MacPhone. Update it."
            case .broken: "Installed but incomplete. Reinstall it."
            case .ready: "Ready."
            }
        }
    }

    private static var requirementsMarker: URL {
        NetsimBridgeProcess.bridgeRuntimeDirectory.appendingPathComponent("installed-requirements.txt")
    }

    static func bundledRequirements() -> String? {
        guard let dir = NetsimBridgeProcess.bridgeDirectory() else { return nil }
        return try? String(contentsOf: dir.appendingPathComponent("requirements.txt"), encoding: .utf8)
    }

    static func bridgeRuntimeState() async -> BridgeRuntimeState {
        let python = NetsimBridgeProcess.bridgePython
        guard FileManager.default.isExecutableFile(atPath: python.path) else { return .missing }
        let installed = try? String(contentsOf: requirementsMarker, encoding: .utf8)
        guard installed != nil, installed == bundledRequirements() else { return .outdated }
        // grpc is what talks to netsim; a plain `bumble` install lacks it.
        let probe = try? await CommandRunner().run(python.path, ["-c", "import bumble, grpc"], timeout: 30)
        return probe?.succeeded == true ? .ready : .broken
    }

    private func installedSimulatorPlatforms() async -> Set<String> {
        guard let catalog = try? await SimulatorService().catalog() else { return [] }
        return Set(catalog.runtimes.map { $0.platform == "xrOS" ? "visionOS" : $0.platform })
    }

    // MARK: Fixes

    func run(_ fix: Dependency.Fix, onLog: @escaping @Sendable (String) -> Void) async throws {
        switch fix {
        case .none, .link:
            return
        case .brewCask(let cask):
            try await brew(["install", "--cask", cask], onLog: onLog)
        case .brewFormula(let formula):
            try await brew(["install", formula], onLog: onLog)
        case .sdkPackages(let packages):
            try await installSDKPackages(packages, onLog: onLog)
        case .commandLineTools:
            try await installCommandLineTools(onLog: onLog)
        case .bridgeRuntime:
            try await installBridgeRuntime(onLog: onLog)
        case .simulatorRuntime(let platform):
            onLog("Downloading the \(platform) runtime from Apple. This takes a while.")
            try await SimulatorService().downloadRuntime(platform: platform, onLine: onLog)
        }
    }

    private func brew(_ arguments: [String], onLog: @escaping @Sendable (String) -> Void) async throws {
        guard let brew = Self.brewPath() else { throw SetupError.brewMissing }
        onLog("brew \(arguments.joined(separator: " "))")
        let code = try await runner.runStreaming(brew, arguments, timeout: 3600, onLine: onLog)
        guard code == 0 else { throw SetupError.commandFailed("Homebrew", code) }
    }

    private func installBridgeRuntime(onLog: @escaping @Sendable (String) -> Void) async throws {
        guard let directory = NetsimBridgeProcess.bridgeDirectory(), let requirements = Self.bundledRequirements() else {
            throw SetupError.bridgeScriptMissing
        }
        guard let python = await Self.python() else { throw SetupError.pythonMissing }
        let runtime = NetsimBridgeProcess.bridgeRuntimeDirectory
        let venv = runtime.appendingPathComponent(".venv")
        try? FileManager.default.removeItem(at: venv)
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)

        onLog("Creating a Python environment with \(python.version).")
        let venvCode = try await runner.runStreaming(python.path, ["-m", "venv", venv.path], timeout: 300, onLine: onLog)
        guard venvCode == 0 else { throw SetupError.commandFailed("python -m venv", venvCode) }

        onLog("Installing \(requirements.trimmingCharacters(in: .whitespacesAndNewlines)).")
        let pip = venv.appendingPathComponent("bin/python").path
        let pipCode = try await runner.runStreaming(
            pip, ["-m", "pip", "install", "--disable-pip-version-check", "-r", directory.appendingPathComponent("requirements.txt").path],
            timeout: 900, onLine: onLog
        )
        guard pipCode == 0 else { throw SetupError.commandFailed("pip install", pipCode) }
        try requirements.write(to: Self.requirementsMarker, atomically: true, encoding: .utf8)
        onLog("Bridge runtime ready.")
    }

    private func installSDKPackages(_ packages: [String], onLog: @escaping @Sendable (String) -> Void) async throws {
        let sdk = AndroidSDK.locateOrDefault()
        guard sdk.hasSdkmanager else { throw SetupError.toolsMissing }
        guard await AndroidSDK.javaHome() != nil else { throw SetupError.javaMissing }
        onLog("Installing \(packages.joined(separator: ", ")).")
        let code = try await runner.runStreaming(
            sdk.sdkmanagerPath, ["--install"] + packages,
            stdin: String(repeating: "y\n", count: 10), timeout: 1800, environment: await sdk.toolEnvironment(), onLine: onLog
        )
        guard code == 0 else { throw SetupError.commandFailed("sdkmanager", code) }
    }

    /// Lays the tools out as `<sdk>/cmdline-tools/latest`, the path sdkmanager expects.
    private func installCommandLineTools(onLog: @escaping @Sendable (String) -> Void) async throws {
        let fm = FileManager.default
        let root = AndroidSDK.locate()?.root ?? AndroidSDK.defaultRoot
        let cmdline = root.appendingPathComponent("cmdline-tools")
        try fm.createDirectory(at: cmdline, withIntermediateDirectories: true)

        onLog("Downloading the Android command-line tools.")
        let (zip, response): (URL, URLResponse)
        do {
            (zip, response) = try await URLSession.shared.download(from: Self.commandLineTools.url)
        } catch {
            throw SetupError.downloadFailed(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw SetupError.downloadFailed("HTTP \(http.statusCode)")
        }
        let digest = Insecure.SHA1.hash(data: try Data(contentsOf: zip)).map { String(format: "%02x", $0) }.joined()
        guard digest == Self.commandLineTools.sha1 else { throw SetupError.checksumMismatch }

        let staging = fm.temporaryDirectory.appendingPathComponent("macphone-cmdline-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: staging) }
        let unzip = try await runner.runStreaming("/usr/bin/ditto", ["-x", "-k", zip.path, staging.path], timeout: 300, onLine: onLog)
        guard unzip == 0 else { throw SetupError.commandFailed("Unpacking", unzip) }

        let latest = cmdline.appendingPathComponent("latest")
        if fm.fileExists(atPath: latest.path) {
            _ = try fm.replaceItemAt(latest, withItemAt: staging.appendingPathComponent("cmdline-tools"))
        } else {
            try fm.moveItem(at: staging.appendingPathComponent("cmdline-tools"), to: latest)
        }
        if UserDefaults.standard.string(forKey: AndroidSDK.customRootKey) == nil, AndroidSDK.locate()?.root != root {
            UserDefaults.standard.set(root.path, forKey: AndroidSDK.customRootKey)
        }
        onLog("Installed to \(latest.path).")
    }
}
