import Foundation

public struct ProcessResult: Sendable {
    public let status: Int32
    public let stdout: Data
    public let stderr: String

    public init(status: Int32, stdout: Data = Data(), stderr: String = "") {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }

    public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
}

public enum ProcessRunnerError: Error, CustomStringConvertible {
    case timedOut(command: String, seconds: TimeInterval)
    case launchFailed(command: String, underlying: Error)
    case nonZeroExit(command: String, status: Int32)

    public var description: String {
        switch self {
        case .timedOut(let command, let seconds):
            return "'\(command)' timed out after \(Int(seconds))s"
        case .launchFailed(let command, let underlying):
            return "could not launch '\(command)': \(underlying.localizedDescription)"
        case .nonZeroExit(let command, let status):
            return "'\(command)' exited with status \(status)"
        }
    }
}

public protocol ProcessRunning: Sendable {
    /// Run `executable` (resolved via $PATH) and capture its output.
    /// Throws `ProcessRunnerError.timedOut` after killing a process that
    /// exceeds `timeout` (pass `.infinity` for commands that legitimately
    /// wait on the user); a nonzero exit is NOT an error at this level.
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async throws -> ProcessResult
}

extension ProcessRunning {
    /// `subprocess.run(check=True)` semantics: nonzero exit throws.
    public func runChecked(
        _ executable: String, _ arguments: [String], timeout: TimeInterval
    ) async throws -> ProcessResult {
        let result = try await run(executable, arguments, timeout: timeout)
        guard result.status == 0 else {
            throw ProcessRunnerError.nonZeroExit(command: executable, status: result.status)
        }
        return result
    }
}

public struct DefaultProcessRunner: ProcessRunning {
    /// Exit status plus whether a signal (e.g. the watchdog's SIGKILL) ended
    /// the child, as reported by the termination handler.
    private struct ChildExit: Sendable {
        let status: Int32
        let killedBySignal: Bool
    }

    public init() {}

    public func run(
        _ executable: String, _ arguments: [String], timeout: TimeInterval
    ) async throws -> ProcessResult {
        let process = Process()
        // /usr/bin/env resolves bare names ("diskutil", "pgrep") via $PATH while
        // passing absolute paths ("/sbin/mount_exfat") through untouched.
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        // Installed before run() so an instantly-exiting child cannot slip
        // past; the stream buffers the exit until it is awaited. The reason
        // rides along so a timeout can be told apart from a natural exit.
        let (terminations, termination) = AsyncStream.makeStream(of: ChildExit.self)
        process.terminationHandler = { process in
            termination.yield(
                ChildExit(
                    status: process.terminationStatus,
                    killedBySignal: process.terminationReason == .uncaughtSignal
                ))
            termination.finish()
        }

        do {
            try process.run()
        } catch {
            throw ProcessRunnerError.launchFailed(command: executable, underlying: error)
        }

        // Drain both pipes while the child runs; draining only after exit
        // deadlocks once a child fills the 64 KiB pipe buffer (diskutil
        // plists can).
        async let stdoutData = Self.drain(outPipe.fileHandleForReading)
        async let stderrData = Self.drain(errPipe.fileHandleForReading)

        let pid = process.processIdentifier
        let watchdog = Self.watchdog(pid: pid, timeout: timeout)

        var childExit: ChildExit?
        for await exit in terminations {
            childExit = exit
        }
        watchdog?.cancel()

        guard let childExit else {
            // Only possible when the surrounding task was cancelled, which
            // ends stream iteration early: reap the child and propagate.
            kill(pid, SIGKILL)
            process.waitUntilExit()
            _ = await (stdoutData, stderrData)
            throw CancellationError()
        }

        let stdout = await stdoutData
        let stderr = await stderrData

        // Timed out only when the watchdog fired AND its SIGKILL is what
        // ended the child — a child that exits on its own in the same instant
        // is a completed command, not a timeout.
        let watchdogFired = await watchdog?.value ?? false
        if watchdogFired && childExit.killedBySignal && childExit.status == SIGKILL {
            throw ProcessRunnerError.timedOut(command: executable, seconds: timeout)
        }

        return ProcessResult(
            status: childExit.status,
            stdout: stdout,
            stderr: String(decoding: stderr, as: UTF8.self)
        )
    }

    /// SIGKILLs `pid` once `timeout` elapses; the task's value reports
    /// whether it fired. An infinite timeout means no watchdog at all — for
    /// commands that legitimately wait on the user (e.g. a password dialog).
    private static func watchdog(pid: pid_t, timeout: TimeInterval) -> Task<Bool, Never>? {
        guard timeout.isFinite else { return nil }
        return Task {
            guard (try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))) != nil else {
                return false  // cancelled — the child exited in time
            }
            kill(pid, SIGKILL)
            return true
        }
    }

    private static func drain(_ handle: FileHandle) async -> Data {
        // readDataToEndOfFile is a blocking read, so it runs on a GCD thread
        // instead of tying up the cooperative pool; it returns on child exit
        // (EOF) at the latest.
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: handle.readDataToEndOfFile())
            }
        }
    }
}
