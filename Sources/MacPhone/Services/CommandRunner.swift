import Foundation

struct CommandResult {
    let exitCode: Int32
    let standardOutput: String
    let standardError: String

    var succeeded: Bool {
        exitCode == 0
    }
}

enum CommandRunnerError: Error, LocalizedError {
    case launchFailed(String)
    case timedOut(String, TimeInterval)

    var errorDescription: String? {
        switch self {
        case .launchFailed(let executable):
            "Could not launch \(executable)."
        case .timedOut(let executable, let seconds):
            "\(executable) timed out after \(Int(seconds))s."
        }
    }
}

actor CommandRunner {
    /// Overlay the given keys onto the current process environment so callers only need to
    /// specify what they add (e.g. JAVA_HOME) without dropping PATH and friends.
    nonisolated static func merged(_ overrides: [String: String]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for (key, value) in overrides { env[key] = value }
        return env
    }

    /// Runs an external process, draining stdout/stderr concurrently so output larger
    /// than the OS pipe buffer (~64 KB, e.g. `simctl list --json`) cannot deadlock the
    /// child. Enforces a wall-clock timeout and terminates the process if it is exceeded.
    func run(
        _ executable: String,
        _ arguments: [String] = [],
        timeout: TimeInterval = 20,
        environment: [String: String]? = nil
    ) async throws -> CommandResult {
        let box = ProcessBox()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()

            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = stdout
            process.standardError = stderr
            if let environment { process.environment = Self.merged(environment) }
            box.adopt(process)

            // Drain both pipes on background reads before waiting, otherwise a child
            // that fills its pipe buffer blocks forever while we block on waitUntilExit.
            let outputBox = DataBox()
            let errorBox = DataBox()
            stdout.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                } else {
                    outputBox.append(chunk)
                }
            }
            stderr.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                } else {
                    errorBox.append(chunk)
                }
            }

            do {
                try process.run()
            } catch {
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                throw CommandRunnerError.launchFailed(executable)
            }

            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning {
                if Date() >= deadline {
                    process.terminate()
                    process.waitUntilExit()
                    stdout.fileHandleForReading.readabilityHandler = nil
                    stderr.fileHandleForReading.readabilityHandler = nil
                    throw CommandRunnerError.timedOut(executable, timeout)
                }
                try? await Task.sleep(nanoseconds: 25_000_000)
            }

            // Detach the handlers BEFORE the final drain: readToEnd() and a still-armed
            // readabilityHandler would otherwise race for the same file descriptor.
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            // Read any remaining buffered bytes the handler may not have flushed.
            if let trailingOut = try? stdout.fileHandleForReading.readToEnd() { outputBox.append(trailingOut) }
            if let trailingErr = try? stderr.fileHandleForReading.readToEnd() { errorBox.append(trailingErr) }

            if box.isCancelled { throw CancellationError() }
            return CommandResult(
                exitCode: process.terminationStatus,
                standardOutput: String(data: outputBox.data, encoding: .utf8) ?? "",
                standardError: String(data: errorBox.data, encoding: .utf8) ?? ""
            )
            }.value
        } onCancel: {
            box.terminate()
        }
    }
}

extension CommandRunner {
    /// Runs a long process (e.g. `sdkmanager` downloading a system image) while streaming
    /// each output line to `onLine` as it arrives, so the UI can show live progress. An
    /// optional `stdin` string is written up front and the pipe closed — used to feed the
    /// repeated "y" that `sdkmanager --licenses` and `avdmanager create` expect. The whole
    /// pipeline is merged (stdout + stderr) since these tools mix progress across both.
    func runStreaming(
        _ executable: String,
        _ arguments: [String] = [],
        stdin: String? = nil,
        timeout: TimeInterval = 1800,
        environment: [String: String]? = nil,
        onLine: @escaping @Sendable (String) -> Void
    ) async throws -> Int32 {
        let box = ProcessBox()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
            let process = Process()
            let output = Pipe()
            let input = Pipe()

            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = output
            process.standardError = output
            process.standardInput = input
            if let environment { process.environment = Self.merged(environment) }
            box.adopt(process)

            let lineBuffer = LineBuffer(onLine: onLine)
            output.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                } else {
                    lineBuffer.feed(chunk)
                }
            }

            do {
                try process.run()
            } catch {
                output.fileHandleForReading.readabilityHandler = nil
                throw CommandRunnerError.launchFailed(executable)
            }

            if let stdin, let data = stdin.data(using: .utf8) {
                try? input.fileHandleForWriting.write(contentsOf: data)
            }
            try? input.fileHandleForWriting.close()

            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning {
                if Date() >= deadline {
                    process.terminate()
                    process.waitUntilExit()
                    output.fileHandleForReading.readabilityHandler = nil
                    throw CommandRunnerError.timedOut(executable, timeout)
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }

            output.fileHandleForReading.readabilityHandler = nil
            if let trailing = try? output.fileHandleForReading.readToEnd() { lineBuffer.feed(trailing) }
            lineBuffer.flush()

            if box.isCancelled { throw CancellationError() }
            return process.terminationStatus
            }.value
        } onCancel: {
            box.terminate()
        }
    }

    /// Starts a long-running process (e.g. the Android emulator) and returns immediately
    /// without waiting for it to exit. Output is discarded; the process keeps running
    /// independently and is controlled afterwards via adb/console.
    func launchDetached(_ executable: String, _ arguments: [String] = []) async throws {
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                throw CommandRunnerError.launchFailed(executable)
            }
        }.value
    }
}

/// Splits streamed pipe data into whole lines, invoking `onLine` per line. `sdkmanager`
/// also rewrites a single progress line with carriage returns, so those are split too.
private final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = ""
    private let onLine: @Sendable (String) -> Void

    init(onLine: @escaping @Sendable (String) -> Void) {
        self.onLine = onLine
    }

    func feed(_ chunk: Data) {
        guard let text = String(data: chunk, encoding: .utf8) else { return }
        lock.lock()
        pending += text
        var emit: [String] = []
        while let idx = pending.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
            let line = String(pending[pending.startIndex..<idx])
            pending = String(pending[pending.index(after: idx)...])
            if !line.isEmpty { emit.append(line) }
        }
        lock.unlock()
        for line in emit { onLine(line) }
    }

    func flush() {
        lock.lock()
        let line = pending.trimmingCharacters(in: .whitespacesAndNewlines)
        pending = ""
        lock.unlock()
        if !line.isEmpty { onLine(line) }
    }
}

/// Bridges Swift task cancellation to the underlying `Process`. The detached run loop only
/// watches `process.isRunning`, so on cancel we terminate the child — the loop then sees it
/// exit and unwinds, and we surface a `CancellationError` instead of a bogus exit code.
private final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    /// Register the process; if cancellation already arrived, terminate it immediately.
    func adopt(_ process: Process) {
        lock.lock()
        self.process = process
        let alreadyCancelled = cancelled
        lock.unlock()
        if alreadyCancelled { process.terminate() }
    }

    func terminate() {
        lock.lock()
        cancelled = true
        let process = self.process
        lock.unlock()
        process?.terminate()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

/// Thread-safe accumulator for pipe reads coming from `readabilityHandler` callbacks,
/// which fire on an arbitrary queue.
private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func append(_ chunk: Data) {
        lock.lock()
        storage.append(chunk)
        lock.unlock()
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
