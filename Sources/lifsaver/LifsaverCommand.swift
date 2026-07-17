import ArgumentParser
import Foundation
import LifsaverCore

/// Force-mount external camera data volumes stuck in macOS Disk Utility limbo.
/// Bypasses automated daemon naming race conditions.
///
/// macOS Tahoe / LIFS compatibility: prefers `diskutil mount` over raw mount
/// binaries, which are increasingly sandbox-restricted in Tahoe's security model.
///
/// Usage:
///     lifsaver           # scan (read-only), confirm, then mount via sudo
@main
struct LifsaverCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lifsaver",
        abstract: "Force-mount stalled 'Untitled' volumes on macOS.",
        version: lifsaverVersion,
        subcommands: [ReportCommand.self]
    )

    @Flag(help: "Show the full mount sequence and raw stderr from mount commands.")
    var verbose = false

    @Flag(help: .hidden)  // machine-readable output on stdout (used by the menu bar app)
    var json = false

    mutating func run() async throws {
        let checker = UpdateChecker(
            package: "lifsaver",
            repo: "lucuma13/lifsaver",
            currentVersion: lifsaverVersion,
            upgradeCommand: lifsaverUpgradeCommand()
        )
        checker.start()
        let status = await CLIMain.run(verbose: verbose, json: json)
        await checker.notify()
        if status != 0 {
            throw ExitCode(status)
        }
    }
}

/// `lifsaver report` — save a diagnostic report for filing a bug. Read-only
/// and root-free; writes the report to ~/Downloads.
struct ReportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "report",
        abstract: "Save a diagnostic report (read-only) to ~/Downloads to attach to a bug report."
    )

    mutating func run() async throws {
        let status = await ReportCLI.run()
        if status != 0 {
            throw ExitCode(status)
        }
    }
}

enum ReportCLI {
    static func run(
        runner: any ProcessRunning = DefaultProcessRunner(),
        mountTable: any MountTableReading = LiveMountTable(),
        directory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads"),
        write: (String, URL) throws -> Void = { try $0.write(to: $1, atomically: true, encoding: .utf8) },
        emit: (String) -> Void = { print($0) },
        emitError: (String) -> Void = { Console.standard.err($0) }
    ) async -> Int32 {
        let reporter = DiagnosticsReporter(runner: runner, mountTable: mountTable)
        let report = await reporter.generate()
        let url = directory.appendingPathComponent(DiagnosticsReporter.suggestedFilename())
        do {
            try write(report, url)
        } catch {
            emitError("Could not save the diagnostic report: \(error)")
            return 1
        }
        emit("Diagnostic report exported to \(url.path). Please email it to \(lifsaverSupportEmail).")
        return 0
    }
}

enum CLIMain {
    static func run(
        verbose: Bool,
        json: Bool,
        runner: any ProcessRunning = DefaultProcessRunner(),
        mountTable: any MountTableReading = LiveMountTable(),
        console explicitConsole: Console? = nil,
        fileOps: any FileOperating = DefaultFileOperations(),
        uid: () -> uid_t = { getuid() },
        emit: (String) -> Void = { print($0) },
        escalate: () -> Int32 = { escalateViaSudo() }
    ) async -> Int32 {
        // In JSON mode stdout carries only the JSON document; every human-facing
        // line is diverted to stderr.
        let console =
            explicitConsole
            ?? (json
                ? Console(out: Console.standard.err, err: Console.standard.err)
                : .standard)
        let scanner = DiskScanner(runner: runner, mountTable: mountTable, console: console, verbose: verbose)

        // Running `sudo lifsaver` directly skips the confirmation prompt — the
        // sudo re-exec in the pre-flight would otherwise ask twice.
        if uid() != 0 {
            return await preflight(scanner: scanner, json: json, emit: emit, escalate: escalate)
        }
        return await mountSequence(mounter: Mounter(scanner: scanner, fileOps: fileOps), json: json, emit: emit)
    }

    /// Non-root pre-flight: scanning is read-only, so find the targets first and
    /// describe them before escalating. sudo's own password prompt acts as the
    /// confirmation — Ctrl+C or a wrong password there aborts with nothing mounted.
    private static func preflight(
        scanner: DiskScanner, json: Bool,
        emit: (String) -> Void, escalate: () -> Int32
    ) async -> Int32 {
        let targets: [String]
        do {
            targets = try await scanner.scanTargets()
        } catch {
            scanner.console.err("CRITICAL: \(error)")
            return 1
        }

        if json {
            // Read-only JSON scan: report targets and stop — never escalate
            // from JSON mode; the caller decides what to do next.
            emitJSON(CLIReport(action: .scan, targets: targets), emit: emit)
            return 0
        }

        guard !targets.isEmpty else {
            scanner.console.out("No stalled or unmounted camera data volumes detected.")
            return 0
        }
        let noun = targets.count == 1 ? "volume" : "volumes"
        scanner.console.out(
            "Would mount \(targets.count) stalled \(noun). If you want to continue, "
                + "please enter your password below (otherwise Ctrl+C to abort, or quit this window):"
        )
        return escalate()
    }

    /// Root path: scan again with fresh eyes, then mount everything found.
    private static func mountSequence(
        mounter: Mounter, json: Bool, emit: (String) -> Void
    ) async -> Int32 {
        let scanner = mounter.scanner
        let console = scanner.console
        let verbose = scanner.verbose

        if verbose {
            console.out(separatorLine)
            console.out("Camera volume mount sequence")
            console.out(separatorLine)
        }

        let targets: [String]
        do {
            targets = try await scanner.scanTargets()
        } catch {
            console.err("CRITICAL: \(error)")
            return 1
        }

        guard !targets.isEmpty else {
            if json {
                emitJSON(CLIReport(action: .mount, targets: [], results: .init(), mounted: []), emit: emit)
            } else {
                console.out("No stalled or unmounted camera data volumes detected.")
                if verbose {
                    console.out(separatorLine)
                }
            }
            return 0
        }

        if verbose {
            console.out("Found \(targets.count) candidate volume(s): \(targets.joined(separator: ", "))")
        }

        let (results, mounted) = await mountAll(targets, mounter: mounter)

        if json {
            emitJSON(CLIReport(action: .mount, targets: targets, results: results, mounted: mounted), emit: emit)
        } else {
            console.out("Done — \(results.ok) mounted, \(results.fail) failed, \(results.skip) skipped.")
        }
        return results.fail > 0 ? 1 : 0
    }

    /// Mount every target in order, tallying outcomes for the report.
    private static func mountAll(
        _ targets: [String], mounter: Mounter
    ) async -> (results: CLIReport.Counts, mounted: [CLIReport.MountedVolume]) {
        let scanner = mounter.scanner
        var results = CLIReport.Counts()
        var mounted: [CLIReport.MountedVolume] = []
        for devId in targets {
            switch await mounter.execute(devId) {
            case .ok:
                results.ok += 1
                mounted.append(.init(device: devId, mountPoint: scanner.mountPoint(of: devId)))
            case .fail:
                results.fail += 1
            case .skip:
                results.skip += 1
            }
            if scanner.verbose {
                scanner.console.out(separatorLine)
            }
        }
        return (results, mounted)
    }

    /// Replace this process with `sudo <this binary> <same args>` via
    /// execvp(3). Never returns on success.
    static func escalateViaSudo() -> Never {
        let executable = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let argv = ["sudo", executable] + CommandLine.arguments.dropFirst()
        var cArgv: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
        cArgv.append(nil)
        execvp("sudo", cArgv)
        // exec only returns on failure
        perror("lifsaver: could not exec sudo")
        exit(1)
    }

    private static func emitJSON(_ report: CLIReport, emit: (String) -> Void) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(report) else { return }
        emit(String(decoding: data, as: UTF8.self))
    }
}
