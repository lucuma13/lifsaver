import Foundation

/// Root side of the app's escalated mount: the menu bar app re-runs its own
/// binary under the administrator password dialog with `helperFlag`, and this
/// scans and mounts everything found, printing a `MountReport` JSON document
/// on stdout for the app to parse.
public enum EscalatedMountHelper {
    /// Hidden argv flag marking an invocation as the escalated helper rather
    /// than the menu bar app. Frozen: an updated app may invoke a not yet
    /// restarted older binary's flag and vice versa.
    public static let helperFlag = "--escalated-mount"

    /// Scan, mount every target, and emit the report. Stdout carries only the
    /// JSON document; diagnostics go to the console (stderr by default, which
    /// the invoking app discards) and are also carried home in the report's
    /// `log`.
    public static func run(
        runner: any ProcessRunning = DefaultProcessRunner(),
        mountTable: any MountTableReading = KernelMountTable(),
        fileOps: any FileOperating = DefaultFileOperations(),
        console: Console = Console(out: Console.standard.err, err: Console.standard.err),
        emit: (String) -> Void = { print($0) }
    ) async -> Int32 {
        let log = ConsoleLog()
        let console = log.console(alsoTo: console)
        // Verbose: skip reasons only ever land in the report log, and "why was
        // my card skipped as root" is exactly what a mount bug report turns on.
        let scanner = DiskScanner(runner: runner, mountTable: mountTable, console: console, verbose: true)

        let targets: [String]
        do {
            targets = try await scanner.scanTargets()
        } catch {
            // The invoking app discards this process's stderr, so the failure
            // must also travel in the JSON report — otherwise the user pays for
            // a password dialog and learns nothing about why it failed.
            console.err("CRITICAL: \(error)")
            emitReport(
                MountReport(targets: [], error: "root-side scan failed: \(error)", log: log.snapshot()),
                emit: emit)
            return 1
        }

        let pass = await Mounter(scanner: scanner, fileOps: fileOps).mountAll(targets)
        emitReport(
            MountReport(targets: targets, results: pass.counts, mounted: pass.mounted, log: log.snapshot()),
            emit: emit)
        return pass.counts.fail > 0 ? 1 : 0
    }

    private static func emitReport(_ report: MountReport, emit: (String) -> Void) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(report) {
            emit(String(decoding: data, as: UTF8.self))
        }
    }
}
