import Foundation
import LifsaverCore

/// Runs the bundled CLI as root through the standard macOS administrator
/// password dialog (`do shell script … with administrator privileges`).
///
/// `do shell script` swallows the inner command's exit status (a nonzero exit
/// raises an AppleScript error instead), so the inner shell always exits 0 and
/// appends a `__EXIT:<n>` sentinel that carries the real status back.
enum EscalatedMount {
    private static let sentinel = "__EXIT:"
    /// AppleScript's userCanceledErr — osascript reports the error code as a
    /// suffix: `execution error: User canceled. (-128)`.
    private static let userCancelledSuffix = "(-128)"

    static func run(runner: any ProcessRunning = DefaultProcessRunner()) async -> EscalatedMountOutcome {
        guard let cliPath = locateCLI() else { return .cliNotFound }

        // Quote for the shell, then escape the whole line for the AppleScript
        // string literal (backslashes first, then double quotes).
        let shellQuotedPath = "'" + cliPath.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let innerCommand = "\(shellQuotedPath) --json 2>/dev/null; printf '\\n\(sentinel)%d' \"$?\""
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
            return .error("missing exit sentinel in CLI output")
        }
        let exitText = stdout[sentinelRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = String(stdout[..<sentinelRange.lowerBound])

        guard
            let jsonStart = payload.firstIndex(of: "{"),
            let report = try? JSONDecoder().decode(CLIReport.self, from: Data(payload[jsonStart...].utf8)),
            let results = report.results
        else {
            let exitCode = Int32(exitText) ?? -1
            return .error("unreadable CLI output (exit \(exitCode))")
        }

        return .report(results)
    }

    /// The CLI ships inside the app at Contents/Helpers/lifsaver. During
    /// development (bare `swift build` binary, no bundle) fall back to the
    /// sibling build product.
    static func locateCLI() -> String? {
        let executable = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
        let candidates = [
            executable
                .deletingLastPathComponent()  // Contents/MacOS
                .deletingLastPathComponent()  // Contents
                .appendingPathComponent("Helpers/lifsaver"),
            executable
                .deletingLastPathComponent()
                .appendingPathComponent("lifsaver"),
        ]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate.path
        }
        return nil
    }
}
