import Foundation

/// Root side of the app's escalated mount: the menu bar app re-runs its own
/// binary under the administrator password dialog with `helperFlag`, and this
/// scans and mounts everything found, printing a `MountReport` JSON document
/// on stdout for the app to parse.
public enum RootMountRunner {
    /// Hidden argv flag marking an invocation as the escalated helper rather
    /// than the menu bar app. Frozen: an updated app may invoke a not yet
    /// restarted older binary's flag and vice versa.
    public static let helperFlag = "--escalated-mount"

    /// Scan, mount every target, and emit the report. Stdout carries only the
    /// JSON document; diagnostics go to the console (stderr by default, which
    /// the invoking app discards).
    public static func run(
        runner: any ProcessRunning = DefaultProcessRunner(),
        mountTable: any MountTableReading = LiveMountTable(),
        fileOps: any FileOperating = DefaultFileOperations(),
        console: Console = Console(out: Console.standard.err, err: Console.standard.err),
        emit: (String) -> Void = { print($0) }
    ) async -> Int32 {
        let scanner = DiskScanner(runner: runner, mountTable: mountTable, console: console)

        let targets: [String]
        do {
            targets = try await scanner.scanTargets()
        } catch {
            console.err("CRITICAL: \(error)")
            return 1
        }

        var results = MountReport.Counts()
        var mounted: [MountReport.MountedVolume] = []
        let mounter = Mounter(scanner: scanner, fileOps: fileOps)
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
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(MountReport(targets: targets, results: results, mounted: mounted)) {
            emit(String(decoding: data, as: UTF8.self))
        }
        return results.fail > 0 ? 1 : 0
    }
}
