import Foundation

struct CommandResult: Sendable {
    let exitCode: Int32
    let standardOutput: String
    let standardError: String

    var succeeded: Bool { exitCode == 0 }
}

enum CommandRunnerError: Error, LocalizedError {
    case launchFailed(String)
    case timedOut(String, TimeInterval)
    case exitedEarly(String, Int32, String)

    var errorDescription: String? {
        switch self {
        case .launchFailed(let executable):
            "Could not launch \(executable)."
        case .timedOut(let executable, let seconds):
            "\(executable) timed out after \(Int(seconds))s."
        case .exitedEarly(let executable, let code, let tail):
            tail.isEmpty
                ? "\(URL(fileURLWithPath: executable).lastPathComponent) exited right away (code \(code))."
                : "\(URL(fileURLWithPath: executable).lastPathComponent) exited right away: \(tail)"
        }
    }
}

/// Runs external tools without ever blocking the calling thread. Pipes are drained on
/// their own threads from the moment the child starts, so a child that writes more than
/// the 64 KB pipe buffer cannot stall, and a timeout escalates from SIGTERM to SIGKILL.
struct CommandRunner: Sendable {
    nonisolated static func merged(_ overrides: [String: String]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for (key, value) in overrides { env[key] = value }
        return env
    }

    func run(
        _ executable: String,
        _ arguments: [String] = [],
        timeout: TimeInterval = 20,
        environment: [String: String]? = nil
    ) async throws -> CommandResult {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        if let environment { process.environment = Self.merged(environment) }

        let outDrain = PipeDrain(stdout.fileHandleForReading)
        let errDrain = PipeDrain(stderr.fileHandleForReading)
        let status = try await Self.execute(process, executable: executable, timeout: timeout)
        let out = await outDrain.collect()
        let err = await errDrain.collect()
        return CommandResult(
            exitCode: status,
            standardOutput: String(decoding: out, as: UTF8.self),
            standardError: String(decoding: err, as: UTF8.self)
        )
    }

    /// Streams merged stdout/stderr line by line, for long downloads whose progress the UI
    /// shows live. `stdin` is written once and closed; `sdkmanager --licenses` and
    /// `avdmanager create` read their answers from it.
    func runStreaming(
        _ executable: String,
        _ arguments: [String] = [],
        stdin: String? = nil,
        timeout: TimeInterval = 1800,
        environment: [String: String]? = nil,
        onLine: @escaping @Sendable (String) -> Void
    ) async throws -> Int32 {
        let process = Process()
        let output = Pipe()
        let input = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        process.standardInput = input
        if let environment { process.environment = Self.merged(environment) }

        let lines = LineBuffer(onLine: onLine)
        let drain = PipeDrain(output.fileHandleForReading) { lines.feed($0) }
        let status = try await Self.execute(process, executable: executable, timeout: timeout) {
            if let stdin, let data = stdin.data(using: .utf8) {
                try? input.fileHandleForWriting.write(contentsOf: data)
            }
            try? input.fileHandleForWriting.close()
        }
        _ = await drain.collect()
        lines.flush()
        return status
    }

    /// Starts a process that outlives this call (the Android emulator). Output goes to
    /// `logFile`. If the process dies within `grace` seconds, its exit is reported with the
    /// last log line, because the emulator otherwise fails silently on a locked AVD or a
    /// missing system image.
    func launchDetached(
        _ executable: String,
        _ arguments: [String] = [],
        logFile: URL? = nil,
        grace: TimeInterval = 4
    ) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice

        var logHandle: FileHandle?
        if let logFile {
            let fm = FileManager.default
            try? fm.createDirectory(at: logFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: logFile.path, contents: nil)
            logHandle = try? FileHandle(forWritingTo: logFile)
        }
        process.standardOutput = logHandle ?? FileHandle.nullDevice
        process.standardError = logHandle ?? FileHandle.nullDevice

        let exit = ExitSignal()
        process.terminationHandler = { exit.fire($0.terminationStatus) }
        do {
            try process.run()
        } catch {
            throw CommandRunnerError.launchFailed(executable)
        }
        try? logHandle?.close()

        let early = await exit.wait(atMost: grace)
        guard let code = early, code != 0 else { return }
        let tail = logFile.flatMap { try? String(contentsOf: $0, encoding: .utf8) }?
            .split(whereSeparator: \.isNewline)
            .last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map(String.init) ?? ""
        throw CommandRunnerError.exitedEarly(executable, code, tail)
    }

    private static func execute(
        _ process: Process,
        executable: String,
        timeout: TimeInterval,
        afterLaunch: () -> Void = {}
    ) async throws -> Int32 {
        try Task.checkCancellation()
        let exit = ExitSignal()
        process.terminationHandler = { exit.fire($0.terminationStatus) }
        do {
            try process.run()
        } catch {
            throw CommandRunnerError.launchFailed(executable)
        }
        afterLaunch()

        let reaper = Reaper(process)
        let watchdog = Task.detached {
            try await Task.sleep(for: .seconds(timeout))
            reaper.stop(timedOut: true)
        }
        let status = await withTaskCancellationHandler {
            await exit.wait()
        } onCancel: {
            reaper.stop(timedOut: false)
        }
        watchdog.cancel()

        if reaper.didTimeOut { throw CommandRunnerError.timedOut(executable, timeout) }
        try Task.checkCancellation()
        return status
    }
}

/// One-shot exit status that can be awaited before or after the process ended.
private final class ExitSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32?
    private var waiters: [CheckedContinuation<Int32?, Never>] = []

    func fire(_ value: Int32) {
        lock.lock()
        guard status == nil else { lock.unlock(); return }
        status = value
        let pending = waiters
        waiters = []
        lock.unlock()
        pending.forEach { $0.resume(returning: value) }
    }

    func wait() async -> Int32 {
        await withCheckedContinuation { (continuation: CheckedContinuation<Int32?, Never>) in
            enqueue(continuation)
        } ?? -1
    }

    /// The exit status if the process ends within `seconds`, otherwise nil.
    func wait(atMost seconds: TimeInterval) async -> Int32? {
        let timer = Task.detached { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            self?.releaseWaiters()
        }
        let value = await withCheckedContinuation { enqueue($0) }
        timer.cancel()
        return value
    }

    private func enqueue(_ continuation: CheckedContinuation<Int32?, Never>) {
        lock.lock()
        if let status {
            lock.unlock()
            continuation.resume(returning: status)
        } else {
            waiters.append(continuation)
            lock.unlock()
        }
    }

    private func releaseWaiters() {
        lock.lock()
        let pending = waiters
        waiters = []
        lock.unlock()
        pending.forEach { $0.resume(returning: nil) }
    }
}

/// Stops a running child: SIGTERM first, SIGKILL if it is still alive three seconds later.
private final class Reaper: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private var stopping = false
    private var timedOut = false

    init(_ process: Process) { self.process = process }

    var didTimeOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timedOut
    }

    func stop(timedOut: Bool) {
        lock.lock()
        if timedOut { self.timedOut = true }
        guard !stopping else { lock.unlock(); return }
        stopping = true
        lock.unlock()

        guard process.isRunning else { return }
        let pid = process.processIdentifier
        process.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) { [process] in
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }
}

/// Reads a pipe to EOF on a dedicated thread. `collect()` waits a short grace period after
/// the child exited: a daemon the child spawned (`adb start-server`) can inherit the pipe
/// and keep it open forever, and that must not hang the caller.
private final class PipeDrain: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private let done = ExitSignal()

    init(_ handle: FileHandle, onChunk: (@Sendable (Data) -> Void)? = nil) {
        Thread.detachNewThread { [self] in
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                lock.lock()
                buffer.append(chunk)
                lock.unlock()
                onChunk?(chunk)
            }
            done.fire(0)
        }
    }

    func collect(grace: TimeInterval = 2) async -> Data {
        _ = await done.wait(atMost: grace)
        return snapshot()
    }

    private func snapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }
}

/// Splits streamed output into lines. `sdkmanager` redraws its progress bar with carriage
/// returns, so `\r` ends a line as well.
private final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private let onLine: @Sendable (String) -> Void

    init(onLine: @escaping @Sendable (String) -> Void) {
        self.onLine = onLine
    }

    func feed(_ chunk: Data) {
        lock.lock()
        pending.append(chunk)
        var emit: [String] = []
        while let index = pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let line = String(decoding: pending[pending.startIndex..<index], as: UTF8.self)
            pending.removeSubrange(pending.startIndex...index)
            if !line.isEmpty { emit.append(line) }
        }
        lock.unlock()
        emit.forEach(onLine)
    }

    func flush() {
        lock.lock()
        let line = String(decoding: pending, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        pending = Data()
        lock.unlock()
        if !line.isEmpty { onLine(line) }
    }
}
