import Foundation
import Observation

/// Launches and supervises the Python netsim bridge (`macphone_netsim_bridge.py`) from
/// inside the app, so the user never has to open a terminal. The bridge connects to this
/// app's BLEBridgeServer (127.0.0.1:8765) and advertises the mirror on the emulator's
/// netsim controller.
@Observable
@MainActor
final class NetsimBridgeProcess {
    private(set) var isRunning = false
    private(set) var statusLine = "Bridge not started."
    private(set) var log: [String] = []
    private(set) var lastError: String?

    private var process: Process?
    private var readHandle: FileHandle?
    private var intentionalStop = false
    /// Bytes after the last newline of the previous chunk; pipe reads split lines arbitrarily.
    private var pendingOutput = Data()

    /// Where the bridge scripts live. Release builds carry them in the app bundle;
    /// development builds can still use an override or the repository checkout.
    /// `nonisolated` so setup checks (off the main actor) can resolve it too.
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
            candidates.append(resources.appendingPathComponent("bridge", isDirectory: true))
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

    nonisolated static func bridgePython(for scriptsDirectory: URL) -> URL {
        let developmentPython = scriptsDirectory.appendingPathComponent(".venv/bin/python")
        if FileManager.default.isExecutableFile(atPath: developmentPython.path) {
            return developmentPython
        }
        return bridgeRuntimeDirectory.appendingPathComponent(".venv/bin/python")
    }

    func start(port: UInt16 = 8765) {
        guard process == nil else { return }
        guard let dir = Self.bridgeDirectory() else {
            fail("Could not find the bridge/ folder. Set MACPHONE_BRIDGE_DIR.")
            return
        }
        let python = Self.bridgePython(for: dir)
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            fail("BLE bridge runtime missing. Open Setup and choose “Set up bridge runtime”.")
            return
        }

        let proc = Process()
        proc.executableURL = python
        proc.arguments = ["-u", dir.appendingPathComponent("macphone_netsim_bridge.py").path]
        proc.currentDirectoryURL = dir
        var env = ProcessInfo.processInfo.environment
        env["MACPHONE_BRIDGE_PORT"] = String(port)
        env["MACPHONE_PARENT_PID"] = String(ProcessInfo.processInfo.processIdentifier)
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
        statusLine = "Starting bridge…"
        append("Launching macphone_netsim_bridge.py on port \(port)…")
    }

    func stop() {
        intentionalStop = true
        readHandle?.readabilityHandler = nil
        readHandle = nil
        process?.terminate()
        process = nil
        isRunning = false
        statusLine = "Bridge stopped."
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
                statusLine = "Advertising on netsim — connect from the emulator."
            } else if trimmed.contains("GATT received") {
                statusLine = "GATT mirrored. " + trimmed
            } else if trimmed.contains("Waiting for the GATT") {
                statusLine = "Waiting for a device in MacPhone…"
            } else if trimmed.lowercased().contains("could not reach") {
                statusLine = trimmed
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
        // A process that ends while we still thought it was running, and that we did not
        // ask to stop, has crashed — say so instead of the neutral "stopped".
        if isRunning && !intentionalStop {
            append("Bridge process exited unexpectedly.")
            if lastError == nil { statusLine = "Bridge exited unexpectedly. Check the log." }
        } else if lastError == nil {
            statusLine = "Bridge stopped."
        }
        if !pendingOutput.isEmpty {
            ingest(String(decoding: pendingOutput, as: UTF8.self))
            pendingOutput = Data()
        }
        isRunning = false
        process = nil
    }

    private func fail(_ message: String) {
        lastError = message
        statusLine = message
        append(message)
        isRunning = false
    }
}
