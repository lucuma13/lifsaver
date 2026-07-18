import Foundation
import LifsaverCore
import os

/// Re-runs the app's own binary as root through the standard macOS
/// administrator password dialog (`do shell script … with administrator
/// privileges`). The helper invocation (marked by `RootMountRunner.helperFlag`)
/// scans and mounts as root, reporting back as JSON on stdout.
///
/// `do shell script` swallows the inner command's exit status (a nonzero exit
/// raises an AppleScript error instead), so the inner shell always exits 0 and
/// appends a `__EXIT:<n>` sentinel that carries the real status back.
enum EscalatedMount {
    private static let sentinel = "__EXIT:"
    /// AppleScript's userCanceledErr — osascript reports the error code as a
    /// suffix: `execution error: User canceled. (-128)`.
    private static let userCancelledSuffix = "(-128)"

    /// When argv carries the helper flag, this process was launched by `run()`
    /// as the root helper: execute the mount sequence and exit. Called from
    /// main.swift before any AppKit setup; never returns in that case.
    static func exitIfHelperInvocation() {
        guard CommandLine.arguments.contains(RootMountRunner.helperFlag) else { return }
        let status = OSAllocatedUnfairLock(initialState: Int32(1))
        let finished = DispatchSemaphore(value: 0)
        Task.detached {
            let result = await RootMountRunner.run()
            status.withLock { $0 = result }
            finished.signal()
        }
        finished.wait()
        exit(status.withLock { $0 })
    }

    static func run(runner: any ProcessRunning = DefaultProcessRunner()) async -> EscalatedMountOutcome {
        let helperPath = Bundle.main.executablePath ?? CommandLine.arguments[0]

        // Quote for the shell, then escape the whole line for the AppleScript
        // string literal (backslashes first, then double quotes).
        let shellQuotedPath = "'" + helperPath.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let innerCommand =
            "\(shellQuotedPath) \(RootMountRunner.helperFlag) 2>/dev/null; printf '\\n\(sentinel)%d' \"$?\""
        let appleScriptBody =
            innerCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(appleScriptBody)\" with administrator privileges"

        let result: ProcessResult
        do {
            // Infinite timeout: the user may leave the password dialog open
            // indefinitely. The runner drains both pipes concurrently off the
            // cooperative pool, so nothing blocks while the dialog waits.
            result = try await runner.run("/usr/bin/osascript", ["-e", script], timeout: .infinity)
        } catch {
            return .error("could not launch osascript: \(error)")
        }

        if result.status != 0 {
            let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if message.hasSuffix(userCancelledSuffix) {
                return .cancelled
            }
            return .error(message)
        }

        return parse(stdout: result.stdoutText)
    }

    private static func parse(stdout: String) -> EscalatedMountOutcome {
        guard let sentinelRange = stdout.range(of: sentinel, options: .backwards) else {
            return .error("missing exit sentinel in helper output")
        }
        let exitText = stdout[sentinelRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = String(stdout[..<sentinelRange.lowerBound])

        guard
            let jsonStart = payload.firstIndex(of: "{"),
            let report = try? JSONDecoder().decode(MountReport.self, from: Data(payload[jsonStart...].utf8))
        else {
            let exitCode = Int32(exitText) ?? -1
            return .error("unreadable helper output (exit \(exitCode))")
        }

        return .report(report.results)
    }
}
