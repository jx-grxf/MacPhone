import Foundation

/// A single environment prerequisite and how to satisfy it.
struct Dependency: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    let satisfied: Bool
    let required: Bool
    let fix: Fix

    enum Fix: Equatable {
        case none
        /// Install a Homebrew cask (needs Homebrew).
        case brewCask(cask: String, label: String)
        /// Install a Homebrew formula (needs Homebrew).
        case brewFormula(formula: String, label: String)
        /// Install SDK packages via sdkmanager (needs command-line tools + Java).
        case sdkmanager(packages: [String], label: String)
        /// Download + unpack the command-line tools into the default SDK root.
        case bootstrapTools(label: String)
        /// Create the bridge Python venv and install Bumble.
        case bridgeVenv(label: String)
        /// Download the latest simulator runtime for an Apple platform.
        case xcodePlatform(platform: String, label: String)
        /// Nothing automatic — point the user at a page / command to run themselves.
        case manual(label: String, url: String?, command: String?)

        var label: String? {
            switch self {
            case .none: nil
            case .brewCask(_, let label), .brewFormula(_, let label),
                 .sdkmanager(_, let label),
                 .bootstrapTools(let label), .bridgeVenv(let label), .manual(let label, _, _): label
            case .xcodePlatform(_, let label): label
            }
        }
    }
}

/// Checks the Mac for everything the fleet needs and installs the missing pieces with
/// first-party / Homebrew tooling, so a fresh machine can be brought online from the app.
struct SetupService {
    private let runner = CommandRunner()

    // Recent stable Android command-line tools. Even if newer ones exist, sdkmanager can
    // self-update afterwards, so a slightly older bootstrap is fine.
    private static let cmdlineToolsURL =
        "https://dl.google.com/android/repository/commandlinetools-mac-13114758_latest.zip"

    static func brewPath() -> String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func androidStudioInstalled() -> Bool {
        ["/Applications/Android Studio.app",
         NSHomeDirectory() + "/Applications/Android Studio.app"]
            .contains { FileManager.default.fileExists(atPath: $0) }
    }

    static func hasIOSSimulatorRuntime() -> Bool {
        guard IOSSimulatorProvisioner.fullXcodeInstalled else { return false }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "list", "runtimes", "--json"]
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return false
        }
        guard process.terminationStatus == 0,
              let root = try? JSONSerialization.jsonObject(
                with: output.fileHandleForReading.readDataToEndOfFile()
              ) as? [String: Any],
              let runtimes = root["runtimes"] as? [[String: Any]]
        else {
            return false
        }
        return runtimes.contains {
            ($0["identifier"] as? String)?.contains("SimRuntime.iOS") == true
                && ($0["isAvailable"] as? Bool ?? true)
        }
    }

    /// Build the current checklist. Pure filesystem inspection — cheap to call on appear.
    func check() -> [Dependency] {
        let sdk = AndroidSDK.locateOrDefault()
        let brew = Self.brewPath()
        let hasJava = AndroidSDK.javaHome() != nil
        let hasStudio = Self.androidStudioInstalled()

        var items: [Dependency] = []

        items.append(Dependency(
            id: "homebrew",
            title: "Homebrew",
            detail: brew.map { "Found at \($0)" } ?? "Not installed — needed for one-click installs.",
            satisfied: brew != nil,
            required: false,
            fix: brew != nil ? .none : .manual(
                label: "How to install",
                url: "https://brew.sh",
                command: "/bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
            )
        ))

        items.append(Dependency(
            id: "java",
            title: "Java runtime (JDK)",
            detail: hasJava
                ? "Found (\(AndroidSDK.javaHome() ?? "")). Required by the SDK tools."
                : "Missing. Android Studio bundles one, or install Temurin.",
            satisfied: hasJava,
            required: true,
            fix: hasJava ? .none
                : (brew != nil ? .brewCask(cask: "android-studio", label: "Install Android Studio")
                              : .manual(label: "Download Android Studio", url: "https://developer.android.com/studio", command: nil))
        ))

        items.append(Dependency(
            id: "android-studio",
            title: "Android Studio (optional)",
            detail: hasStudio ? "Installed." : "Not installed. Optional — gives a GUI SDK manager and the JDK.",
            satisfied: hasStudio,
            required: false,
            fix: hasStudio ? .none
                : (brew != nil ? .brewCask(cask: "android-studio", label: "Install Android Studio")
                              : .manual(label: "Download", url: "https://developer.android.com/studio", command: nil))
        ))

        items.append(Dependency(
            id: "cmdline-tools",
            title: "Android command-line tools",
            detail: sdk.hasSdkmanager
                ? "Found in \(sdk.root.path)."
                : "Missing. Needed to download system images and create emulators.",
            satisfied: sdk.hasSdkmanager,
            required: true,
            fix: sdk.hasSdkmanager ? .none : .bootstrapTools(label: "Download command-line tools")
        ))

        items.append(Dependency(
            id: "platform-tools",
            title: "Platform tools (adb)",
            detail: sdk.hasADB ? "Found." : "Missing. Provides adb for talking to emulators.",
            satisfied: sdk.hasADB,
            required: true,
            fix: sdk.hasADB ? .none : .sdkmanager(packages: ["platform-tools"], label: "Install platform-tools")
        ))

        items.append(Dependency(
            id: "emulator",
            title: "Emulator engine",
            detail: sdk.hasEmulator ? "Found." : "Missing. The QEMU-based Android emulator.",
            satisfied: sdk.hasEmulator,
            required: true,
            fix: sdk.hasEmulator ? .none : .sdkmanager(packages: ["emulator"], label: "Install emulator")
        ))

        let hasXcode = IOSSimulatorProvisioner.fullXcodeInstalled
        items.append(Dependency(
            id: "xcode",
            title: "Xcode",
            detail: hasXcode
                ? "Full Xcode is installed and selected."
                : "Missing. Required to create and run iOS simulators.",
            satisfied: hasXcode,
            required: true,
            fix: hasXcode ? .none : .manual(
                label: "Get Xcode",
                url: "https://apps.apple.com/app/xcode/id497799835",
                command: nil
            )
        ))

        let hasIOSRuntime = Self.hasIOSSimulatorRuntime()
        items.append(Dependency(
            id: "ios-runtime",
            title: "iOS Simulator runtime",
            detail: hasIOSRuntime
                ? "At least one iOS runtime is installed."
                : (hasXcode
                    ? "Missing. Download the latest runtime from Apple."
                    : "Install Xcode first, then download an iOS runtime."),
            satisfied: hasIOSRuntime,
            required: true,
            fix: hasIOSRuntime || !hasXcode
                ? .none
                : .xcodePlatform(platform: "iOS", label: "Download runtime")
        ))

        let python = Self.python3Path()
        items.append(Dependency(
            id: "python",
            title: "Python runtime",
            detail: python.map { "Found at \($0)." }
                ?? "Missing. Needed for the BLE-to-emulator bridge.",
            satisfied: python != nil,
            required: false,
            fix: python != nil ? .none
                : (brew != nil ? .brewFormula(formula: "python", label: "Install Python")
                               : .manual(label: "Install Homebrew first", url: "https://brew.sh", command: nil))
        ))

        // The scripts ship inside release builds, while the writable Python venv lives
        // in Application Support. Development checkouts may continue using bridge/.venv.
        let bridgeDir = NetsimBridgeProcess.bridgeDirectory()
        let venvReady = bridgeDir.map {
            FileManager.default.isExecutableFile(
                atPath: NetsimBridgeProcess.bridgePython(for: $0).path
            )
        } ?? false
        let runtimePath = bridgeDir.map { NetsimBridgeProcess.bridgePython(for: $0).deletingLastPathComponent().deletingLastPathComponent() }
        items.append(Dependency(
            id: "ble-bridge",
            title: "BLE bridge runtime (Python + Bumble)",
            detail: bridgeDir == nil
                ? "Bundled bridge scripts are missing. Reinstall MacPhone."
                : (venvReady ? "Ready at \(runtimePath!.path)."
                             : "Missing. Needed to mirror a BLE device into the Android emulator."),
            satisfied: venvReady,
            required: false,
            fix: venvReady || bridgeDir == nil || python == nil
                ? .none
                : .bridgeVenv(label: "Set up bridge runtime")
        ))

        return items
    }

    /// Run the fix for a dependency, streaming progress.
    func run(_ fix: Dependency.Fix, onLog: @escaping @Sendable (String) -> Void) async throws {
        switch fix {
        case .none, .manual:
            return
        case .brewCask(let cask, _):
            try await installBrewCask(cask, onLog: onLog)
        case .brewFormula(let formula, _):
            try await installBrewFormula(formula, onLog: onLog)
        case .sdkmanager(let packages, _):
            try await installSdkPackages(packages, onLog: onLog)
        case .bootstrapTools:
            try await bootstrapCommandLineTools(onLog: onLog)
        case .bridgeVenv:
            try await bootstrapBridgeVenv(onLog: onLog)
        case .xcodePlatform(let platform, _):
            try await downloadXcodePlatform(platform, onLog: onLog)
        }
    }

    enum SetupError: LocalizedError {
        case brewMissing
        case toolsMissing
        case javaMissing
        case bridgeDirMissing
        case pythonMissing
        case xcodeMissing
        case downloadFailed(String)
        case unpackFailed(Int32)
        case commandFailed(String, Int32)

        var errorDescription: String? {
            switch self {
            case .brewMissing: "Homebrew is not installed. Install it first (see the Homebrew row)."
            case .toolsMissing: "Command-line tools missing. Install them first."
            case .javaMissing: "No Java runtime. Install Android Studio or Temurin first."
            case .bridgeDirMissing: "Bundled bridge scripts are missing. Reinstall MacPhone."
            case .pythonMissing: "No python3 found. Install it (e.g. brew install python) and retry."
            case .xcodeMissing: "Full Xcode is not installed. Install Xcode first."
            case .downloadFailed(let m): "Download failed: \(m)"
            case .unpackFailed(let c): "Unpacking the tools failed (ditto exit \(c))."
            case .commandFailed(let tool, let c): "\(tool) failed (exit \(c))."
            }
        }
    }

    /// Locate a usable python3 interpreter without assuming a shell PATH.
    static func python3Path() -> String? {
        ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Create a writable venv in Application Support and install Bumble.
    private func bootstrapBridgeVenv(onLog: @escaping @Sendable (String) -> Void) async throws {
        guard NetsimBridgeProcess.bridgeDirectory() != nil else {
            throw SetupError.bridgeDirMissing
        }
        guard let python = Self.python3Path() else { throw SetupError.pythonMissing }
        let runtime = NetsimBridgeProcess.bridgeRuntimeDirectory
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        let venv = runtime.appendingPathComponent(".venv")

        onLog("Creating Python venv at \(venv.path)…")
        let venvCode = try await runner.runStreaming(
            python, ["-m", "venv", venv.path], timeout: 300, onLine: onLog
        )
        guard venvCode == 0 else { throw SetupError.commandFailed("python -m venv", venvCode) }

        onLog("Installing Bumble into the venv…")
        let venvPython = venv.appendingPathComponent("bin/python").path
        let pipCode = try await runner.runStreaming(
            venvPython, ["-m", "pip", "install", "--upgrade", "bumble"], timeout: 600, onLine: onLog
        )
        guard pipCode == 0 else { throw SetupError.commandFailed("pip install bumble", pipCode) }
        onLog("BLE bridge runtime ready.")
    }

    private func installBrewCask(_ cask: String, onLog: @escaping @Sendable (String) -> Void) async throws {
        guard let brew = Self.brewPath() else { throw SetupError.brewMissing }
        onLog("Installing \(cask) via Homebrew (this can take a while)…")
        let code = try await runner.runStreaming(brew, ["install", "--cask", cask], timeout: 1800, onLine: onLog)
        guard code == 0 else { throw SetupError.commandFailed("brew", code) }
        onLog("\(cask) installed.")
    }

    private func installBrewFormula(_ formula: String, onLog: @escaping @Sendable (String) -> Void) async throws {
        guard let brew = Self.brewPath() else { throw SetupError.brewMissing }
        onLog("Installing \(formula) via Homebrew…")
        let code = try await runner.runStreaming(
            brew, ["install", formula], timeout: 1800, onLine: onLog
        )
        guard code == 0 else { throw SetupError.commandFailed("brew", code) }
        onLog("\(formula) installed.")
    }

    private func downloadXcodePlatform(
        _ platform: String,
        onLog: @escaping @Sendable (String) -> Void
    ) async throws {
        guard IOSSimulatorProvisioner.fullXcodeInstalled else {
            throw SetupError.xcodeMissing
        }
        onLog("Downloading the latest \(platform) Simulator runtime from Apple…")
        onLog("This is a large download and can take several minutes.")
        let code = try await runner.runStreaming(
            "/usr/bin/xcodebuild",
            ["-downloadPlatform", platform],
            timeout: 7_200,
            onLine: onLog
        )
        guard code == 0 else {
            throw SetupError.commandFailed("xcodebuild -downloadPlatform \(platform)", code)
        }
        onLog("\(platform) Simulator runtime installed.")
    }

    private func installSdkPackages(_ packages: [String], onLog: @escaping @Sendable (String) -> Void) async throws {
        let sdk = AndroidSDK.locateOrDefault()
        guard sdk.hasSdkmanager else { throw SetupError.toolsMissing }
        guard AndroidSDK.javaHome() != nil else { throw SetupError.javaMissing }
        onLog("Installing: \(packages.joined(separator: ", "))…")
        let code = try await runner.runStreaming(
            sdk.sdkmanagerPath, ["--install"] + packages,
            stdin: "y\n", timeout: 1200, environment: sdk.toolEnvironment(), onLine: onLog
        )
        guard code == 0 else { throw SetupError.commandFailed("sdkmanager", code) }
        onLog("Installed: \(packages.joined(separator: ", ")).")
    }

    /// Download the command-line tools zip and lay it out at <root>/cmdline-tools/latest.
    private func bootstrapCommandLineTools(onLog: @escaping @Sendable (String) -> Void) async throws {
        let fm = FileManager.default
        let root = AndroidSDK.defaultRoot
        let cmdlineDir = root.appendingPathComponent("cmdline-tools")
        try? fm.createDirectory(at: cmdlineDir, withIntermediateDirectories: true)

        guard let url = URL(string: Self.cmdlineToolsURL) else {
            throw SetupError.downloadFailed("bad URL")
        }
        onLog("Downloading command-line tools…")
        let (tempZip, response): (URL, URLResponse)
        do {
            (tempZip, response) = try await URLSession.shared.download(from: url)
        } catch {
            throw SetupError.downloadFailed(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw SetupError.downloadFailed("HTTP \(http.statusCode)")
        }
        onLog("Unpacking…")

        // Unzip into a staging dir, then move the extracted "cmdline-tools" → "latest".
        let staging = fm.temporaryDirectory.appendingPathComponent("macphone-cmdline-\(UUID().uuidString)")
        try? fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let unzipCode = try await runner.runStreaming(
            "/usr/bin/ditto", ["-x", "-k", tempZip.path, staging.path], timeout: 300, onLine: onLog
        )
        guard unzipCode == 0 else { throw SetupError.unpackFailed(unzipCode) }

        let extracted = staging.appendingPathComponent("cmdline-tools")
        let latest = cmdlineDir.appendingPathComponent("latest")
        if fm.fileExists(atPath: latest.path) { try? fm.removeItem(at: latest) }
        try fm.moveItem(at: extracted, to: latest)
        try? fm.removeItem(at: staging)
        onLog("Command-line tools installed at \(latest.path).")
    }
}
