import Foundation
import Testing

@testable import LifsaverCore

// ===========================================================================
// Escalated helper mount sequence
// ===========================================================================

/// Fake runner + mount table emulating a full scan-and-mount environment with
/// one external Microsoft Basic Data partition per device id.
private func scenario(
    devices: [String], diskutilMountSucceeds: Bool = true,
    diskutilListSucceeds: Bool = true, fsckActive: Bool = false
) -> (runner: FakeProcessRunner, mountTable: FakeMountTable) {
    let mountTable = FakeMountTable()
    let listData = plistData([
        "AllDisksAndPartitions": [
            [
                "DeviceIdentifier": "disk4",
                "Partitions": devices.map {
                    ["DeviceIdentifier": $0, "Content": "Microsoft Basic Data"]
                },
            ]
        ]
    ])
    let wholeDiskInfo = plistData(infoExternal)
    let partitionInfo = plistData(["FilesystemType": "exfat"])
    let runner = FakeProcessRunner { executable, arguments in
        switch executable {
        case "pgrep":
            // pgrep exits 1 when no fsck is running; a match lists the raw device.
            guard fsckActive else { return ProcessResult(status: 1) }
            let listing = devices.map { "501 fsck_exfat /dev/r\($0)" }.joined(separator: "\n")
            return ProcessResult(status: 0, stdout: Data(listing.utf8))
        case "diskutil" where arguments.first == "list":
            guard diskutilListSucceeds else { return ProcessResult(status: 1) }
            return ProcessResult(status: 0, stdout: listData)
        case "diskutil" where arguments.first == "info" && arguments.last == "disk4":
            // Whole-disk externality query (hardware location lives only here).
            return ProcessResult(status: 0, stdout: wholeDiskInfo)
        case "diskutil" where arguments.first == "info":
            return ProcessResult(status: 0, stdout: partitionInfo)
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

private struct HelperRun {
    var status: Int32
    var emitted: [String]
    var console: CapturedConsole

    /// The emitted stdout document decoded as the app would decode it.
    func decodedReport() throws -> MountReport {
        try JSONDecoder().decode(MountReport.self, from: Data(emitted.joined().utf8))
    }
}

private func runHelper(
    devices: [String],
    diskutilMountSucceeds: Bool = true,
    diskutilListSucceeds: Bool = true,
    fsckActive: Bool = false
) async -> HelperRun {
    let (runner, mountTable) = scenario(
        devices: devices, diskutilMountSucceeds: diskutilMountSucceeds,
        diskutilListSucceeds: diskutilListSucceeds, fsckActive: fsckActive)
    let console = CapturedConsole()
    var emitted: [String] = []
    let status = await RootMountRunner.run(
        runner: runner,
        mountTable: mountTable,
        fileOps: FakeFileOperations(),
        console: console.console,
        emit: { emitted.append($0) }
    )
    return HelperRun(status: status, emitted: emitted, console: console)
}

@Suite struct RootMountRunnerTests {
    @Test func mountsEachTargetAndRoundTripsThroughSharedReportType() async throws {
        // The app decodes this exact output as MountReport — assert the full
        // document round-trips, not just substrings.
        let run = await runHelper(devices: ["disk4s1"])
        #expect(run.status == 0)
        let report = try run.decodedReport()
        #expect(report.targets == ["disk4s1"])
        #expect(report.results == MountReport.Counts(ok: 1, fail: 0, skip: 0))
        #expect(report.mounted == [MountReport.MountedVolume(device: "disk4s1", mountPoint: "/Volumes/CARD")])
    }

    @Test func emptyScanStillEmitsWellFormedReport() async throws {
        // The app parses every run's output, so the empty case must still be
        // a well-formed report rather than a human-readable sentence.
        let run = await runHelper(devices: [])
        #expect(run.status == 0)
        let report = try run.decodedReport()
        #expect(report.targets.isEmpty)
        #expect(report.mounted.isEmpty)
        #expect(report.results == MountReport.Counts(ok: 0, fail: 0, skip: 0))
    }

    @Test func exitsNonZeroWhenAMountFails() async throws {
        let run = await runHelper(devices: ["disk4s1"], diskutilMountSucceeds: false)
        #expect(run.status == 1)
        let report = try run.decodedReport()
        #expect(report.results == MountReport.Counts(ok: 0, fail: 1, skip: 0))
    }

    @Test func failedScanReportsCriticalAndEmitsNothing() async {
        // Stdout must never carry a half-report the app would misparse.
        let run = await runHelper(devices: ["disk4s1"], diskutilListSucceeds: false)
        #expect(run.status == 1)
        #expect(run.emitted.isEmpty)
        #expect(run.console.errText.contains("CRITICAL"))
    }

    @Test func activeFsckSkipsTargetRatherThanMounting() async throws {
        // A skipped volume is not a failure — nothing was left in a bad state.
        let run = await runHelper(devices: ["disk4s1"], fsckActive: true)
        #expect(run.status == 0)
        let report = try run.decodedReport()
        #expect(report.results == MountReport.Counts(ok: 0, fail: 0, skip: 1))
    }
}
