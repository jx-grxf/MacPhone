import Foundation
import Observation

/// Runs `macphone_netsim_bridge.py`, which connects to `BLEBridgeServer` and advertises the
/// mirror on the emulator's netsim controller.
@Observable
@MainActor
final class NetsimBridgeProcess {
    private(set) var isRunning = false
    private(set) var statusLine = "Off"
    private(set) var log: [String] = []
    private(set) var lastError: String?

    private var process: Process?
    private var readHandle: FileHandle?
    private var intentionalStop = false
    private var lastPort: UInt16 = 8765
    private var lastToken = ""
    /// The bridge exits with this code when the Mac switched to a device with a different
    /// GATT. Bumble cannot swap services while advertising, so it gets a fresh start.
    private static let exitGATTChanged: Int32 = 75
    /// Bytes after the last newline of the previous chunk; pipe reads split lines arbitrarily.
    private var pendingOutput = Data()

    /// Release builds carry the script in Contents/Resources; a development build run from
    /// the repository finds `bridge/` next to it.
    nonisolated static func bridgeDirectory() -> URL? {
        let fm = FileManager.default
        func hasScript(_ dir: URL) -> Bool {
            fm.fileExists(atPath: dir.appendingPathComponent("macphone_netsim_bridge.py").path)
        }

        if let override = ProcessInfo.processInfo.environment["MACPHONE_BRIDGE_DIR"] {
            let dir = URL(fileURLWithPath: override)
            if hasScript(dir) { return dir }
        }

        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources)
        }
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)
        candidates.append(cwd.appendingPathComponent("bridge"))

        // Walk up from the executable location looking for a sibling `bridge/`.
        var dir = URL(fileURLWithPath: Bundle.main.bundlePath).deletingLastPathComponent()
        for _ in 0..<8 {
            candidates.append(dir.appendingPathComponent("bridge"))
            dir = dir.deletingLastPathComponent()
        }
        return candidates.first(where: hasScript)
    }

    /// Writable location for the Python environment used by bundled release builds.
    nonisolated static var bridgeRuntimeDirectory: URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return support
            .appendingPathComponent("MacPhone", isDirectory: true)
            .appendingPathComponent("bridge-runtime", isDirectory: true)
    }

    nonisolated static var bridgePython: URL {
        bridgeRuntimeDirectory.appendingPathComponent(".venv/bin/python")
    }

    func start(port: UInt16, token: String) {
        guard process == nil else { return }
        lastPort = port
        lastToken = token
        guard let dir = Self.bridgeDirectory() else {
            fail("The bridge script is missing from the app. Reinstall MacPhone.")
            return
        }
        let python = Self.bridgePython
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            fail("The bridge runtime is not installed. Open Setup and install it.")
            return
        }

        let proc = Process()
        proc.executableURL = python
        proc.arguments = ["-u", dir.appendingPathComponent("macphone_netsim_bridge.py").path]
        proc.currentDirectoryURL = dir
        var env = ProcessInfo.processInfo.environment
        env["MACPHONE_BRIDGE_PORT"] = String(port)
        env["MACPHONE_PARENT_PID"] = String(ProcessInfo.processInfo.processIdentifier)
        env["MACPHONE_BRIDGE_TOKEN"] = token
        proc.environment = env

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                // EOF: stop polling, otherwise the handler keeps firing with empty data.
                handle.readabilityHandler = nil
                return
            }
            Task { @MainActor in self?.ingest(chunk, from: proc) }
        }

        // Only the process we currently own may reset state: after a quick Stop → Start the
        // old bridge exits late and must not mark the new one as stopped.
        proc.terminationHandler = { [weak self] ended in
            Task { @MainActor in self?.processEnded(ended) }
        }

        do {
            try proc.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            fail("Could not start the bridge: \(error.localizedDescription)")
            return
        }
        process = proc
        readHandle = pipe.fileHandleForReading
        intentionalStop = false
        isRunning = true
        lastError = nil
        pendingOutput = Data()
        log = []
        statusLine = "Starting the bridge"
        append("Starting the netsim bridge.")
    }

    func stop() {
        intentionalStop = true
        readHandle?.readabilityHandler = nil
        readHandle = nil
        process?.terminate()
        process = nil
        isRunning = false
        statusLine = "Stopped"
    }

    private func ingest(_ chunk: Data, from source: Process) {
        guard source === process else { return }
        pendingOutput.append(chunk)
        // Decode only whole lines, so a line (or a multi-byte character) split across two
        // reads is neither logged in pieces nor dropped as invalid UTF-8.
        guard let lastNewline = pendingOutput.lastIndex(of: 0x0A) else { return }
        let complete = pendingOutput[pendingOutput.startIndex...lastNewline]
        pendingOutput = Data(pendingOutput[pendingOutput.index(after: lastNewline)...])
        ingest(String(decoding: complete, as: UTF8.self))
    }

    private func ingest(_ text: String) {
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            append(trimmed)
            // Surface the most meaningful states as the one-line status.
            if trimmed.contains("Advertising on netsim") {
                statusLine = "Visible in the emulator"
            } else if trimmed.contains("Waiting for the GATT") {
                statusLine = "Waiting for a device"
            } else if trimmed.contains("ModuleNotFoundError") || trimmed.contains("No module named") {
                lastError = "The bridge runtime is incomplete. Open Setup and reinstall it."
            } else if trimmed.localizedCaseInsensitiveContains("netsim") && trimmed.localizedCaseInsensitiveContains("error") {
                lastError = "netsim is not reachable. Start an Android emulator first."
            }
        }
    }

    private func append(_ line: String) {
        log.append(line)
        if log.count > 400 { log.removeFirst(log.count - 400) }
    }

    private func processEnded(_ ended: Process) {
        guard ended === process else { return }
        readHandle?.readabilityHandler = nil
        readHandle = nil
        if !pendingOutput.isEmpty {
            ingest(String(decoding: pendingOutput, as: UTF8.self))
            pendingOutput = Data()
        }
        isRunning = false
        process = nil

        if !intentionalStop && ended.terminationStatus == Self.exitGATTChanged {
            append("Device changed; restarting the bridge.")
            start(port: lastPort, token: lastToken)
            return
        }
        if !intentionalStop {
            let reason = lastError ?? log.last { !$0.hasPrefix("[") } ?? "exit code \(ended.terminationStatus)"
            lastError = "The bridge stopped: \(reason)"
            statusLine = "Stopped unexpectedly"
        } else {
            statusLine = "Stopped"
        }
    }

    private func fail(_ message: String) {
        lastError = message
        statusLine = message
        append(message)
        isRunning = false
    }
}
