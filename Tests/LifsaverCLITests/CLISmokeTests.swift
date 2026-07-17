import Foundation
import Testing
import os

@testable import LifsaverCore
@testable import lifsaver

// ---------------------------------------------------------------------------
// Local fakes (this target cannot see LifsaverCoreTests helpers)
// ---------------------------------------------------------------------------

private final class RecordingRunner: ProcessRunning {
    private let handler: @Sendable (String, [String]) throws -> ProcessResult

    init(handler: @escaping @Sendable (String, [String]) throws -> ProcessResult) {
        self.handler = handler
    }

    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async throws -> ProcessResult {
        try handler(executable, arguments)
    }
}

private final class InMemoryMountTable: MountTableReading {
    private let state = OSAllocatedUnfairLock(initialState: [MountEntry]())

    func add(device: String, mountPoint: String) {
        state.withLock { $0.append(MountEntry(device: device, mountPoint: mountPoint)) }
    }

    func entries() throws -> [MountEntry] {
        state.withLock { $0 }
    }
}

private struct NoOpFileOperations: FileOperating {
    func createDirectory(at path: String) throws {}
    func removeEmptyDirectory(at path: String) {}
}

private final class Captured {
    // Console closures are @Sendable, so those sinks live in a locked box;
    // emitted/escalated are only touched by synchronous non-Sendable closures.
    private let lines = OSAllocatedUnfairLock(initialState: (out: [String](), err: [String]()))
    var emitted: [String] = []
    var escalated = false

    var out: [String] { lines.withLock { $0.out } }
    var err: [String] { lines.withLock { $0.err } }

    var console: Console {
        Console(
            out: { [lines] line in lines.withLock { $0.out.append(line) } },
            err: { [lines] line in lines.withLock { $0.err.append(line) } }
        )
    }

    var outText: String { out.joined(separator: "\n") }
    var errText: String { err.joined(separator: "\n") }
}

private func plist(_ object: Any) -> Data {
    // swiftlint:disable:next force_try
    try! PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
}

/// diskutil plist with one external Microsoft Basic Data partition per device id.
private func diskDataPlist(devices: [String]) -> Data {
    plist([
        "AllDisksAndPartitions": [
            [
                "DeviceIdentifier": "disk4",
                "Partitions": devices.map {
                    ["DeviceIdentifier": $0, "Content": "Microsoft Basic Data"]
                },
            ]
        ]
    ])
}

/// Fake runner + mount table emulating a full scan-and-mount environment.
private func scenario(
    devices: [String], diskutilMountSucceeds: Bool = true,
    diskutilListSucceeds: Bool = true, fsckActive: Bool = false
) -> (runner: RecordingRunner, mountTable: InMemoryMountTable) {
    let mountTable = InMemoryMountTable()
    let runner = RecordingRunner { executable, arguments in
        switch executable {
        case "pgrep":
            // pgrep exits 1 when no fsck is running; a match lists the raw device.
            guard fsckActive else { return ProcessResult(status: 1) }
            let listing = devices.map { "501 fsck_exfat /dev/r\($0)" }.joined(separator: "\n")
            return ProcessResult(status: 0, stdout: Data(listing.utf8))
        case "diskutil" where arguments.first == "list":
            guard diskutilListSucceeds else { return ProcessResult(status: 1) }
            return ProcessResult(status: 0, stdout: diskDataPlist(devices: devices))
        case "diskutil" where arguments.first == "info" && arguments.last == "disk4":
            // Whole-disk externality query (hardware location lives only here).
            return ProcessResult(
                status: 0, stdout: plist(["Internal": false, "RemovableMediaOrExternalDevice": true]))
        case "diskutil" where arguments.first == "info":
            return ProcessResult(status: 0, stdout: plist(["FilesystemType": "exfat"]))
        case "diskutil" where arguments.first == "mount":
            if diskutilMountSucceeds {
                mountTable.add(device: "/dev/\(arguments[1])", mountPoint: "/Volumes/CARD")
                return ProcessResult(status: 0)
            }
            return ProcessResult(status: 1)
        default:
            return ProcessResult(status: 1)
        }
    }
    return (runner, mountTable)
}

private func runCLI(
    verbose: Bool = false,
    json: Bool = false,
    devices: [String],
    diskutilMountSucceeds: Bool = true,
    diskutilListSucceeds: Bool = true,
    fsckActive: Bool = false,
    uid: uid_t,
    captured: Captured
) async -> Int32 {
    let (runner, mountTable) = scenario(
        devices: devices, diskutilMountSucceeds: diskutilMountSucceeds,
        diskutilListSucceeds: diskutilListSucceeds, fsckActive: fsckActive)
    return await CLIMain.run(
        verbose: verbose, json: json,
        runner: runner,
        mountTable: mountTable,
        console: captured.console,
        fileOps: NoOpFileOperations(),
        uid: { uid },
        emit: { captured.emitted.append($0) },
        escalate: {
            captured.escalated = true
            return 0
        }
    )
}

// ===========================================================================
// Non-root pre-flight (sudo escalation)
// ===========================================================================

@Suite struct PreflightTests {
    @Test func noTargetsPrintsMessageWithoutEscalating() async {
        let captured = Captured()
        let status = await runCLI(devices: [], uid: 501, captured: captured)
        #expect(status == 0)
        #expect(!captured.escalated)
        #expect(captured.outText.contains("No stalled or unmounted camera data volumes detected."))
    }

    @Test func targetsPromptThenEscalate() async {
        let captured = Captured()
        _ = await runCLI(devices: ["disk4s1"], uid: 501, captured: captured)
        #expect(captured.escalated)
        #expect(captured.outText.contains("Would mount 1 stalled volume."))
    }

    @Test func preflightMessagePluralizesVolumeCount() async {
        let captured = Captured()
        _ = await runCLI(devices: ["disk4s1", "disk4s2"], uid: 501, captured: captured)
        #expect(captured.escalated)
        #expect(captured.outText.contains("Would mount 2 stalled volumes."))
    }

    @Test func jsonScanNeverEscalates() async {
        let captured = Captured()
        let status = await runCLI(json: true, devices: ["disk4s1"], uid: 501, captured: captured)
        #expect(status == 0)
        #expect(!captured.escalated)
        #expect(captured.emitted.joined().contains("\"targets\":[\"disk4s1\"]"))
    }

    @Test func failedScanReportsCriticalWithoutEscalating() async {
        let captured = Captured()
        let status = await runCLI(
            devices: ["disk4s1"], diskutilListSucceeds: false, uid: 501, captured: captured)
        #expect(status == 1)
        // A scan we cannot trust must never lead to a password prompt.
        #expect(!captured.escalated)
        #expect(captured.errText.contains("CRITICAL"))
        #expect(captured.errText.contains("Failed to query diskutil"))
    }
}

// ===========================================================================
// Root mount sequence
// ===========================================================================

@Suite struct MountSequenceTests {
    @Test func rootDoesNotEscalate() async {
        let captured = Captured()
        _ = await runCLI(devices: [], uid: 0, captured: captured)
        #expect(!captured.escalated)
        #expect(captured.outText.contains("No stalled or unmounted camera data volumes detected."))
    }

    @Test func mountsEachTargetAndSummarizes() async {
        let captured = Captured()
        let status = await runCLI(verbose: true, devices: ["disk4s1", "disk4s2"], uid: 0, captured: captured)
        #expect(status == 0)
        #expect(captured.outText.contains("Found 2 candidate volume(s): disk4s1, disk4s2"))
        #expect(captured.outText.contains("Done — 2 mounted, 0 failed, 0 skipped."))
    }

    @Test func exitsNonZeroWhenAMountFails() async {
        let captured = Captured()
        let status = await runCLI(
            devices: ["disk4s1"], diskutilMountSucceeds: false, uid: 0, captured: captured)
        #expect(status == 1)
        #expect(captured.outText.contains("Done — 0 mounted, 1 failed, 0 skipped."))
    }

    @Test func jsonMountReportsResults() async {
        let captured = Captured()
        let status = await runCLI(json: true, devices: ["disk4s1"], uid: 0, captured: captured)
        #expect(status == 0)
        let json = captured.emitted.joined()
        #expect(json.contains("\"action\":\"mount\""))
        #expect(json.contains("\"ok\":1"))
        #expect(json.contains("\"mountPoint\":\"\\/Volumes\\/CARD\""))
    }

    @Test func failedScanReportsCriticalAndMountsNothing() async {
        let captured = Captured()
        let status = await runCLI(
            devices: ["disk4s1"], diskutilListSucceeds: false, uid: 0, captured: captured)
        #expect(status == 1)
        #expect(captured.errText.contains("CRITICAL"))
        #expect(!captured.outText.contains("Done —"))
    }

    @Test func activeFsckSkipsTargetRatherThanMounting() async {
        let captured = Captured()
        let status = await runCLI(devices: ["disk4s1"], fsckActive: true, uid: 0, captured: captured)
        // A skipped volume is not a failure — nothing was left in a bad state.
        #expect(status == 0)
        #expect(captured.outText.contains("consistency check (fsck)"))
        #expect(captured.outText.contains("Done — 0 mounted, 0 failed, 1 skipped."))
    }

    @Test func verboseEmptyScanStillPrintsBanner() async {
        let captured = Captured()
        let status = await runCLI(verbose: true, devices: [], uid: 0, captured: captured)
        #expect(status == 0)
        #expect(captured.outText.contains("Camera volume mount sequence"))
        #expect(captured.outText.contains("No stalled or unmounted camera data volumes detected."))
    }

    @Test func jsonMountWithNoTargetsEmitsEmptyReport() async throws {
        let captured = Captured()
        let status = await runCLI(json: true, devices: [], uid: 0, captured: captured)
        #expect(status == 0)
        // The app parses every run's output, so the empty case must still be
        // a well-formed mount report rather than a human-readable sentence.
        let report = try JSONDecoder().decode(CLIReport.self, from: Data(captured.emitted.joined().utf8))
        #expect(report.action == .mount)
        #expect(report.targets.isEmpty)
        #expect(report.mounted == [])
        #expect(report.results == CLIReport.Counts(ok: 0, fail: 0, skip: 0))
    }

    @Test func jsonMountRoundTripsThroughSharedReportType() async throws {
        // The app decodes this exact output as CLIReport — assert the full
        // document round-trips, not just substrings.
        let captured = Captured()
        _ = await runCLI(json: true, devices: ["disk4s1"], uid: 0, captured: captured)
        let report = try JSONDecoder().decode(CLIReport.self, from: Data(captured.emitted.joined().utf8))
        #expect(report.action == .mount)
        #expect(report.results == CLIReport.Counts(ok: 1, fail: 0, skip: 0))
        #expect(report.mounted == [CLIReport.MountedVolume(device: "disk4s1", mountPoint: "/Volumes/CARD")])
    }
}

// ===========================================================================
// Default console wiring (real stdout/stderr)
// ===========================================================================

/// Redirect the process-wide stdout/stderr file descriptors to temp files for
/// the duration of `body`, returning what each received.
///
/// This is the only way to exercise CLIMain's *default* console: passing a
/// console explicitly short-circuits the very wiring under test.
private func capturingStandardStreams(
    _ body: () async -> Void
) async -> (out: String, err: String) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let outURL = directory.appendingPathComponent("stdout")
    let errURL = directory.appendingPathComponent("stderr")
    FileManager.default.createFile(atPath: outURL.path, contents: nil)
    FileManager.default.createFile(atPath: errURL.path, contents: nil)

    let outFD = open(outURL.path, O_WRONLY)
    let errFD = open(errURL.path, O_WRONLY)
    let savedOut = dup(STDOUT_FILENO)
    let savedErr = dup(STDERR_FILENO)
    dup2(outFD, STDOUT_FILENO)
    dup2(errFD, STDERR_FILENO)

    await body()

    // print() is fully buffered when stdout is a file rather than a tty.
    fflush(stdout)
    fflush(stderr)
    dup2(savedOut, STDOUT_FILENO)
    dup2(savedErr, STDERR_FILENO)
    for descriptor in [savedOut, savedErr, outFD, errFD] { close(descriptor) }

    let out = (try? String(contentsOf: outURL, encoding: .utf8)) ?? ""
    let err = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
    try? FileManager.default.removeItem(at: directory)
    return (out, err)
}

/// Serialized: redirecting stdout/stderr mutates process-global state, so these
/// must not run alongside anything else writing to the real streams.
@Suite(.serialized) struct DefaultConsoleTests {
    /// The menu bar app decodes stdout verbatim, so a stray human-readable line
    /// on stdout in --json mode is a parse failure for the app. Guards the
    /// `json ? Console(out: .err, err: .err) : .standard` wiring, which every
    /// other test bypasses by injecting a console.
    @Test func jsonModeKeepsStdoutPureAndDivertsProseToStderr() async throws {
        let (runner, mountTable) = scenario(devices: [])
        let (out, err) = await capturingStandardStreams {
            let status = await CLIMain.run(
                verbose: true, json: true,
                runner: runner, mountTable: mountTable,
                fileOps: NoOpFileOperations(),
                uid: { 0 },
                escalate: { 1 }
            )
            #expect(status == 0)
        }

        // Note: these streams also carry the test harness's own progress output,
        // since the redirect is process-wide and other suites run in parallel.
        // Assert on lifsaver's contribution rather than byte-purity.
        let reportLine = try #require(out.split(separator: "\n").first { $0.hasPrefix("{") })
        let report = try JSONDecoder().decode(CLIReport.self, from: Data(reportLine.utf8))
        #expect(report.action == .mount)

        // The verbose banner is prose: stderr only, never stdout.
        #expect(!out.contains("Camera volume mount sequence"))
        #expect(err.contains("Camera volume mount sequence"))
    }

    @Test func humanModeSendsProseToStdout() async {
        let (runner, mountTable) = scenario(devices: [])
        let (out, _) = await capturingStandardStreams {
            _ = await CLIMain.run(
                verbose: true, json: false,
                runner: runner, mountTable: mountTable,
                fileOps: NoOpFileOperations(),
                uid: { 0 },
                escalate: { 1 }
            )
        }
        #expect(out.contains("Camera volume mount sequence"))
        #expect(out.contains("No stalled or unmounted camera data volumes detected."))
    }
}

// ===========================================================================
// Built binary smoke test
// ===========================================================================

@Suite struct BinarySmokeTests {
    private final class BundleMarker {}

    private var binaryURL: URL {
        // The test bundle sits in the same build products directory as the
        // compiled `lifsaver` executable.
        Bundle(for: BundleMarker.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("lifsaver")
    }

    @Test func versionFlagPrintsBareVersionAndExitsZero() throws {
        let process = Process()
        process.executableURL = binaryURL
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let output = String(
            decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == lifsaverVersion)
    }
}
