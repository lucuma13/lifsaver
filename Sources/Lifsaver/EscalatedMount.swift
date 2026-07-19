import Foundation
import LifsaverKit
import os

/// Mounts stalled volumes in two passes, escalating only when it buys
/// something, then re-runs the app's own binary as root through the standard
/// macOS administrator password dialog (`do shell script … with administrator
/// privileges`) for whatever the unprivileged pass could not reach. The helper
/// invocation (marked by `EscalatedMountHelper.helperFlag`) scans and mounts as
/// root, reporting back as JSON on stdout.
///
/// `do shell script` swallows the inner command's exit status (a nonzero exit
/// raises an AppleScript error instead), so the inner shell always exits 0 and
/// appends a `__EXIT:<n>` sentinel that carries the real status back.
enum EscalatedMount {
    private static let sentinel = "__EXIT:"
    /// AppleScript's userCanceledErr — osascript reports the code in a trailing
    /// parenthesis: `execution error: User canceled. (-128)`.
    private static let userCancelledCode = -128

    struct Outcome: Sendable {
        var unprivileged: MountReport.Counts
        /// nil when the first pass left nothing for root to do — the case where
        /// the user is never asked for a password at all.
        var escalated: EscalatedMountOutcome?
        /// Timestamped console lines the root helper recorded, carried in-band
        /// because the escalation plumbing discards the helper's stderr.
        var helperLog: [String] = []
    }

    /// Two-pass mount so the password dialog only appears when it buys
    /// something.
    ///
    /// `diskutil mount` mounts external removable media as the logged-in user,
    /// so the first pass runs in-process with no privileges and no prompt. Only
    /// if it leaves a volume unmounted — the raw `/sbin/mount_*` fallback needs
    /// root — does the app re-run its own binary under the admin dialog, which
    /// rescans as root and picks up whatever is left.
    static func run(scanner: DiskScanner) async -> Outcome {
        let targets: [String]
        do {
            targets = try await scanner.scanTargets()
        } catch {
            // Escalating would only reach the same failing scan under root, so
            // report it rather than spend a password dialog on it.
            return Outcome(unprivileged: .init(), escalated: .error("scan failed: \(error)"))
        }

        // First pass: diskutil only, no escalation. A `.fail` here means
        // "needs root", not "impossible".
        let counts = await Mounter(scanner: scanner, allowRawFallback: false).mountAll(targets).counts
        guard counts.fail > 0 else { return Outcome(unprivileged: counts, escalated: nil) }
        let (escalated, helperLog) = await escalate()
        return Outcome(unprivileged: counts, escalated: escalated, helperLog: helperLog)
    }

    /// When argv carries the helper flag, this process was launched by
    /// `escalate()` as the root helper: execute the mount sequence and exit.
    /// Called from main.swift before any AppKit setup; never returns in that
    /// case.
    static func exitIfHelperInvocation() {
        guard CommandLine.arguments.contains(EscalatedMountHelper.helperFlag) else { return }
        let status = OSAllocatedUnfairLock(initialState: Int32(1))
        let finished = DispatchSemaphore(value: 0)
        Task.detached {
            let result = await EscalatedMountHelper.run()
            status.withLock { $0 = result }
            finished.signal()
        }
        finished.wait()
        exit(status.withLock { $0 })
    }

    /// Second pass: re-run our own binary as root through the password dialog.
    /// Alongside the outcome, returns whatever log lines the helper carried
    /// back in its report (empty on cancel or launch failure).
    static func escalate(
        runner: any ProcessRunning = DefaultProcessRunner()
    ) async -> (outcome: EscalatedMountOutcome, helperLog: [String]) {
        // Resolve symlinks first and validate + execute the same resolved path,
        // so the checked file is the file the password launches.
        let helperPath = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
            .resolvingSymlinksInPath().path
        if let reason = escalationSafetyError(forExecutableAt: helperPath) {
            return (.error("refusing to escalate: \(reason)"), [])
        }

        // Capture the helper's stderr to a temp file instead of discarding it:
        // a helper that crashes before it can emit its JSON report (dyld
        // failure, a TCC denial as root) would otherwise be a black hole — no
        // stdout, no stderr — in exactly the privileged path a diagnostic
        // report exists to explain. Read on failure, below; always cleaned up.
        let stderrPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("lifsaver-helper-\(UUID().uuidString).stderr")
        defer { try? FileManager.default.removeItem(atPath: stderrPath) }

        // Quote for the shell, then escape the whole line for the AppleScript
        // string literal (backslashes first, then double quotes).
        let shellQuotedPath = "'" + helperPath.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let shellQuotedStderr = "'" + stderrPath.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let innerCommand =
            "\(shellQuotedPath) \(EscalatedMountHelper.helperFlag) 2>\(shellQuotedStderr); "
            + "printf '\\n\(sentinel)%d' \"$?\""
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
            return (.error("could not launch osascript: \(error)"), [])
        }

        let helperStderr =
            (try? String(contentsOfFile: stderrPath, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if result.status != 0 {
            let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if appleScriptErrorCode(from: message) == userCancelledCode {
                return (.cancelled, [])
            }
            return (.error(annotate(message, withStderr: helperStderr)), [])
        }

        return parse(stdout: result.stdoutText, helperStderr: helperStderr)
    }

    /// Appends the helper's captured stderr to an error message when there is
    /// any — the difference between "unreadable helper output" and knowing the
    /// helper died on a code-signing or permission error.
    private static func annotate(_ message: String, withStderr stderr: String) -> String {
        stderr.isEmpty ? message : message + "\n\nhelper stderr:\n" + stderr
    }

    /// The numeric code from a trailing "(<code>)" in an osascript error
    /// message, or nil. Parsing the code instead of pinning one rendered string
    /// keeps cancel detection working if the message text around the code ever
    /// changes.
    private static func appleScriptErrorCode(from message: String) -> Int? {
        guard
            message.hasSuffix(")"),
            let open = message.lastIndex(of: "(")
        else { return nil }
        return Int(message[message.index(after: open)..<message.index(before: message.endIndex)])
    }

    /// The path about to be re-executed as root must not be swappable by other
    /// unprivileged processes while the password dialog is up: require a
    /// regular file owned by root or by us, with no group/other write bit. (A
    /// fully user-writable parent directory can still be swapped under us; this
    /// refuses the plainly unsafe cases without breaking dev builds, which are
    /// user-owned 755 binaries.)
    private static func escalationSafetyError(forExecutableAt path: String) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
            return "cannot inspect helper binary at \(path)"
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            return "helper binary at \(path) is not a regular file"
        }
        let owner = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value
        guard owner == 0 || owner == getuid() else {
            return "helper binary at \(path) is owned by another user"
        }
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.int16Value ?? 0
        guard permissions & 0o022 == 0 else {
            return "helper binary at \(path) is writable by other users"
        }
        return nil
    }

    private static func parse(
        stdout: String, helperStderr: String
    ) -> (outcome: EscalatedMountOutcome, helperLog: [String]) {
        guard let sentinelRange = stdout.range(of: sentinel, options: .backwards) else {
            return (.error(annotate("missing exit sentinel in helper output", withStderr: helperStderr)), [])
        }
        let exitText = stdout[sentinelRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = String(stdout[..<sentinelRange.lowerBound])

        guard
            let jsonStart = payload.firstIndex(of: "{"),
            let report = try? JSONDecoder().decode(MountReport.self, from: Data(payload[jsonStart...].utf8))
        else {
            let exitCode = Int32(exitText) ?? -1
            return (.error(annotate("unreadable helper output (exit \(exitCode))", withStderr: helperStderr)), [])
        }

        // A helper that reached this point emitted its report, so a root-side
        // failure it detected arrives in-band via `error` and its timestamped
        // `log` — richer than the raw stderr, which only helps when the helper
        // died before it could report at all.
        if let error = report.error {
            return (.error(error), report.log)
        }
        return (.report(report.results), report.log)
    }
}
