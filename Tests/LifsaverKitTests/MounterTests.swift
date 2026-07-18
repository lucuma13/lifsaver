import Foundation
import Testing
import os

@testable import LifsaverKit

/// Records mount-point directory operations; optionally fails creation.
final class FakeFileOperations: FileOperating {
    private let state = OSAllocatedUnfairLock(initialState: (created: [String](), removed: [String]()))
    private let createError: (any Error & Sendable)?

    init(createError: (any Error & Sendable)? = nil) {
        self.createError = createError
    }

    var createdPaths: [String] { state.withLock { $0.created } }
    var removedPaths: [String] { state.withLock { $0.removed } }

    func createDirectory(at path: String) throws {
        if let createError { throw createError }
        state.withLock { $0.created.append(path) }
    }

    func removeEmptyDirectory(at path: String) {
        state.withLock { $0.removed.append(path) }
    }
}

func makeMounter(
    runner: FakeProcessRunner = FakeProcessRunner(),
    mountTable: any MountTableReading = FakeMountTable(),
    fileOps: FakeFileOperations = FakeFileOperations(),
    console: Console = .standard,
    verbose: Bool = false,
    allowRawFallback: Bool = true
) -> Mounter {
    Mounter(
        scanner: DiskScanner(runner: runner, mountTable: mountTable, console: console, verbose: verbose),
        fileOps: fileOps,
        allowRawFallback: allowRawFallback
    )
}

// ===========================================================================
// diskutilMount
// ===========================================================================

@Suite struct DiskutilMountTests {
    @Test func returnsTrueOnSuccess() async {
        let mounter = makeMounter(runner: FakeProcessRunner(always: ProcessResult(status: 0)))
        #expect(await mounter.diskutilMount("disk4s1"))
    }

    @Test func returnsFalseOnFailure() async {
        let mounter = makeMounter(runner: FakeProcessRunner(always: ProcessResult(status: 1)))
        #expect(!(await mounter.diskutilMount("disk4s1")))
    }

    @Test func returnsFalseWhenRunnerThrows() async {
        let captured = CapturedConsole()
        let runner = FakeProcessRunner(
            throwing: ProcessRunnerError.launchFailed(
                command: "diskutil", underlying: CocoaError(.fileNoSuchFile)))
        let mounter = makeMounter(runner: runner, console: captured.console, verbose: true)
        #expect(!(await mounter.diskutilMount("disk4s1")))
        #expect(captured.errText.contains("[diskutil error]"))
    }

    @Test func printsStderrWhenVerbose() async {
        let captured = CapturedConsole()
        let runner = FakeProcessRunner(always: ProcessResult(status: 1, stderr: "oops"))
        _ = await makeMounter(runner: runner, console: captured.console, verbose: true).diskutilMount("disk4s1")
        #expect(captured.errText.contains("oops"))
    }

    @Test func silentOnStderrWhenNotVerbose() async {
        let captured = CapturedConsole()
        let runner = FakeProcessRunner(always: ProcessResult(status: 1, stderr: "oops"))
        _ = await makeMounter(runner: runner, console: captured.console).diskutilMount("disk4s1")
        #expect(captured.errText.isEmpty)
    }
}

// ===========================================================================
// rawMount
// ===========================================================================

@Suite struct RawMountTests {
    @Test func exfatTriedFirstForUnknownFS() async {
        let runner = FakeProcessRunner(always: ProcessResult(status: 0))
        _ = await makeMounter(runner: runner).rawMount("disk4s1", fsType: "")
        #expect(runner.calls[0].executable.contains("mount_exfat"))
    }

    @Test func msdosTriedFirstForFat32() async {
        let runner = FakeProcessRunner(always: ProcessResult(status: 0))
        _ = await makeMounter(runner: runner).rawMount("disk4s1", fsType: "msdos")
        #expect(runner.calls[0].executable.contains("mount_msdos"))
    }

    @Test func fallsBackToSecondBinary() async {
        let callCount = OSAllocatedUnfairLock(initialState: 0)
        let runner = FakeProcessRunner { _, _ in
            let count = callCount.withLock { count in
                count += 1
                return count
            }
            return ProcessResult(status: count == 1 ? 1 : 0)
        }
        #expect(await makeMounter(runner: runner).rawMount("disk4s1", fsType: ""))
    }

    @Test func missingFirstBinaryFallsThroughToSecond() async {
        // mount_exfat was removed in newer macOS: launching it throws rather
        // than exiting non-zero, and must not abort the candidate sequence.
        let captured = CapturedConsole()
        let runner = FakeProcessRunner { executable, _ in
            guard executable.contains("mount_exfat") else { return ProcessResult(status: 0) }
            throw ProcessRunnerError.launchFailed(
                command: executable, underlying: CocoaError(.fileNoSuchFile))
        }
        let mounter = makeMounter(runner: runner, console: captured.console, verbose: true)
        #expect(await mounter.rawMount("disk4s1", fsType: ""))
        #expect(captured.errText.contains("[mount_exfat error]"))
        #expect(runner.calls.count == 2)
        #expect(runner.calls[1].executable.contains("mount_msdos"))
    }

    @Test func returnsFalseWhenBothFail() async {
        let fileOps = FakeFileOperations()
        let runner = FakeProcessRunner(always: ProcessResult(status: 1))
        let result = await makeMounter(runner: runner, fileOps: fileOps).rawMount("disk4s1", fsType: "")
        #expect(!result)
        #expect(fileOps.removedPaths == ["/Volumes/Camera_Data_disk4s1"])
    }

    @Test func returnsFalseWhenMountPointCreationFails() async {
        let captured = CapturedConsole()
        let fileOps = FakeFileOperations(
            createError: CocoaError(
                .fileWriteNoPermission,
                userInfo: [
                    NSLocalizedDescriptionKey: "read-only /Volumes"
                ]))
        let runner = FakeProcessRunner(always: ProcessResult(status: 0))
        let mounter = makeMounter(runner: runner, fileOps: fileOps, console: captured.console, verbose: true)
        let result = await mounter.rawMount("disk4s1", fsType: "")
        #expect(!result)
        #expect(runner.calls.isEmpty)
        #expect(captured.errText.contains("read-only /Volumes"))
    }

    @Test func rmdirNotCalledOnSuccess() async {
        let fileOps = FakeFileOperations()
        let runner = FakeProcessRunner(always: ProcessResult(status: 0))
        _ = await makeMounter(runner: runner, fileOps: fileOps).rawMount("disk4s1", fsType: "")
        #expect(fileOps.removedPaths.isEmpty)
    }

    @Test func verboseStderrPrintedOnFailure() async {
        let captured = CapturedConsole()
        let runner = FakeProcessRunner(always: ProcessResult(status: 1, stderr: "bad device"))
        _ = await makeMounter(runner: runner, console: captured.console, verbose: true).rawMount("disk4s1", fsType: "")
        #expect(captured.errText.contains("bad device"))
    }
}

// ===========================================================================
// execute
// ===========================================================================

/// Simulates the full command surface execute() touches: pgrep, diskutil
/// info/mount, and the raw mount binaries — plus the mount table a successful
/// mount command mutates.
private final class MountScenario: Sendable {
    private struct Config: Sendable {
        var pgrepOutput = ""
        var fsType = "exfat"
        var diskutilMountSucceeds = false
        var rawMountSucceeds = false
        /// When true, a successful mount command also updates the mount table.
        var deviceAppearsAfterMount = true
        var commandsSeen: [String] = []
    }

    let table: FakeMountTable
    private let config: OSAllocatedUnfairLock<Config>

    init(
        mounted: [MountEntry] = [],
        pgrepOutput: String = "",
        fsType: String = "exfat",
        diskutilMountSucceeds: Bool = false,
        rawMountSucceeds: Bool = false,
        deviceAppearsAfterMount: Bool = true
    ) {
        table = FakeMountTable(mounted)
        config = OSAllocatedUnfairLock(
            initialState: Config(
                pgrepOutput: pgrepOutput,
                fsType: fsType,
                diskutilMountSucceeds: diskutilMountSucceeds,
                rawMountSucceeds: rawMountSucceeds,
                deviceAppearsAfterMount: deviceAppearsAfterMount
            ))
    }

    var commandsSeen: [String] { config.withLock { $0.commandsSeen } }

    var runner: FakeProcessRunner {
        FakeProcessRunner { [config, table] executable, arguments in
            let snapshot = config.withLock { state in
                state.commandsSeen.append(([executable] + arguments).joined(separator: " "))
                return state
            }
            switch executable {
            case "pgrep":
                return ProcessResult(
                    status: snapshot.pgrepOutput.isEmpty ? 1 : 0, stdout: Data(snapshot.pgrepOutput.utf8))
            case "diskutil" where arguments.first == "info":
                return ProcessResult(status: 0, stdout: plistData(["FilesystemType": snapshot.fsType]))
            case "diskutil" where arguments.first == "mount":
                if snapshot.diskutilMountSucceeds {
                    if snapshot.deviceAppearsAfterMount {
                        table.add(device: "/dev/\(arguments[1])", mountPoint: "/Volumes/CARD")
                    }
                    return ProcessResult(status: 0)
                }
                return ProcessResult(status: 1)
            case let raw where raw.contains("mount_"):
                if snapshot.rawMountSucceeds {
                    let device = (arguments.first ?? "").replacingOccurrences(of: "/dev/", with: "")
                    if snapshot.deviceAppearsAfterMount {
                        table.add(device: "/dev/\(device)", mountPoint: "/Volumes/Camera_Data_\(device)")
                    }
                    return ProcessResult(status: 0)
                }
                return ProcessResult(status: 1)
            default:
                return ProcessResult(status: 1)
            }
        }
    }

    func mounter(
        console: Console = .standard, verbose: Bool = false,
        fileOps: FakeFileOperations = FakeFileOperations(),
        allowRawFallback: Bool = true
    ) -> Mounter {
        makeMounter(
            runner: runner, mountTable: table, fileOps: fileOps, console: console,
            verbose: verbose, allowRawFallback: allowRawFallback)
    }
}

@Suite struct ExecuteMountTests {
    @Test func skipsIfMountedSinceScan() async {
        let captured = CapturedConsole()
        let scenario = MountScenario(mounted: [MountEntry(device: "/dev/disk4s1", mountPoint: "/Volumes/CARD")])
        let outcome = await scenario.mounter(console: captured.console).execute("disk4s1")
        #expect(outcome == .skip)
        #expect(captured.outText.contains("SKIPPED"))
    }

    @Test func skipsWhenFsckIsActive() async {
        let captured = CapturedConsole()
        let scenario = MountScenario(pgrepOutput: "812 fsck_exfat -y /dev/rdisk4s1\n")
        let outcome = await scenario.mounter(console: captured.console).execute("disk4s1")
        #expect(outcome == .skip)
        #expect(captured.outText.contains("consistency check"))
        #expect(!scenario.commandsSeen.contains { $0.contains("diskutil mount") })
        #expect(!scenario.commandsSeen.contains { $0.contains("mount_") })
    }

    @Test func succeedsViaDiskutil() async {
        let scenario = MountScenario(diskutilMountSucceeds: true)
        let outcome = await scenario.mounter().execute("disk4s1")
        #expect(outcome == .ok)
        #expect(!scenario.commandsSeen.contains { $0.contains("mount_exfat") })
    }

    @Test func fallsBackToRawMountWhenDiskutilFails() async {
        let scenario = MountScenario(diskutilMountSucceeds: false, rawMountSucceeds: true)
        let outcome = await scenario.mounter().execute("disk4s1")
        #expect(outcome == .ok)
        #expect(scenario.commandsSeen.contains { $0.contains("mount_exfat") })
    }

    @Test func returnsFailWhenAllStrategiesFail() async {
        let captured = CapturedConsole()
        let scenario = MountScenario()
        let outcome = await scenario.mounter(console: captured.console).execute("disk4s1")
        #expect(outcome == .fail)
        #expect(captured.outText.contains("CRITICAL ERROR"))
    }

    @Test func failsWhenMountCommandLiesAboutSuccess() async {
        // A mount command that exits 0 without the device appearing in the
        // mount table must not count as success, and must not leave the
        // mount-point directory it was given behind.
        let fileOps = FakeFileOperations()
        let scenario = MountScenario(
            diskutilMountSucceeds: true, rawMountSucceeds: true, deviceAppearsAfterMount: false)
        let outcome = await scenario.mounter(fileOps: fileOps).execute("disk4s1")
        #expect(outcome == .fail)
        #expect(fileOps.removedPaths == ["/Volumes/Camera_Data_disk4s1"])
    }

    @Test func verboseAnnouncesRawMountFallbackAndSuccess() async {
        let captured = CapturedConsole()
        let scenario = MountScenario(
            fsType: "exfat", diskutilMountSucceeds: false, rawMountSucceeds: true)
        let outcome = await scenario.mounter(console: captured.console, verbose: true).execute("disk4s1")
        #expect(outcome == .ok)
        #expect(captured.outText.contains("falling back to raw mount binaries"))
        #expect(captured.outText.contains("SUCCESS via raw mount → /Volumes/Camera_Data_disk4s1"))
    }

    @Test func verboseReportsDetectedFilesystem() async {
        let captured = CapturedConsole()
        let scenario = MountScenario(fsType: "exfat", diskutilMountSucceeds: true)
        _ = await scenario.mounter(console: captured.console, verbose: true).execute("disk4s1")
        #expect(captured.outText.contains("Detected filesystem: exfat"))
        #expect(captured.outText.contains("SUCCESS via diskutil"))
    }
}

// ===========================================================================
// execute — unprivileged pass (allowRawFallback: false)
// ===========================================================================

@Suite struct UnprivilegedExecuteTests {
    @Test func succeedsViaDiskutilWithoutRoot() async {
        let scenario = MountScenario(diskutilMountSucceeds: true)
        let outcome = await scenario.mounter(allowRawFallback: false).execute("disk4s1")
        #expect(outcome == .ok)
    }

    @Test func neverRunsRawMountBinaries() async {
        // The raw binaries need root: reaching them unprivileged would spend a
        // failed mount attempt on a volume the escalated pass is about to redo.
        let fileOps = FakeFileOperations()
        let scenario = MountScenario(diskutilMountSucceeds: false, rawMountSucceeds: true)
        let outcome = await scenario.mounter(fileOps: fileOps, allowRawFallback: false).execute("disk4s1")
        #expect(outcome == .fail)
        #expect(!scenario.commandsSeen.contains { $0.contains("mount_") })
        #expect(fileOps.createdPaths.isEmpty)
    }

    @Test func doesNotClaimAllStrategiesFailed() async {
        // diskutil declining is a routine hand-off to the escalated pass, not
        // the dead end the root path's CRITICAL ERROR describes.
        let captured = CapturedConsole()
        let scenario = MountScenario(diskutilMountSucceeds: false)
        _ = await scenario.mounter(console: captured.console, allowRawFallback: false).execute("disk4s1")
        #expect(!captured.outText.contains("CRITICAL ERROR"))
    }

    @Test func verboseExplainsTheHandOff() async {
        let captured = CapturedConsole()
        let scenario = MountScenario(diskutilMountSucceeds: false)
        _ = await scenario.mounter(console: captured.console, verbose: true, allowRawFallback: false)
            .execute("disk4s1")
        #expect(captured.outText.contains("needs elevated privileges"))
    }

    @Test func stillSkipsWhenFsckIsActive() async {
        let scenario = MountScenario(pgrepOutput: "812 fsck_exfat -y /dev/rdisk4s1\n", diskutilMountSucceeds: true)
        let outcome = await scenario.mounter(allowRawFallback: false).execute("disk4s1")
        #expect(outcome == .skip)
        #expect(!scenario.commandsSeen.contains { $0.contains("diskutil mount") })
    }
}

// ===========================================================================
// execute — unreadable mount table
// ===========================================================================

@Suite struct UnreadableMountTableTests {
    @Test func trustsMountExitStatusWhenTableUnreadable() async {
        // An unreadable table is "unknown", not "unmounted": the mount
        // binary's zero exit stands, so the pass doesn't report a spurious
        // failure and trigger an unwarranted admin password prompt upstream.
        let runner = FakeProcessRunner { executable, arguments in
            switch executable {
            case "pgrep":
                return ProcessResult(status: 1)
            case "diskutil" where arguments.first == "info":
                return ProcessResult(status: 0, stdout: plistData(["FilesystemType": "exfat"]))
            default:
                return ProcessResult(status: 0)
            }
        }
        let mounter = makeMounter(runner: runner, mountTable: FakeMountTable(throwing: POSIXError(.EIO)))
        #expect(await mounter.execute("disk4s1") == .ok)
    }
}

// ===========================================================================
// mountAll (shared by the unprivileged pass and the root helper)
// ===========================================================================

/// Runner where `diskutil mount` succeeds per `mountSucceeds`, updating the
/// mount table on success the way the real command does.
private func mountingRunner(
    table: FakeMountTable, mountSucceeds: @escaping @Sendable (String) -> Bool
) -> FakeProcessRunner {
    FakeProcessRunner { executable, arguments in
        switch executable {
        case "pgrep":
            return ProcessResult(status: 1)
        case "diskutil" where arguments.first == "info":
            return ProcessResult(status: 0, stdout: plistData(["FilesystemType": "exfat"]))
        case "diskutil" where arguments.first == "mount":
            let devId = arguments[1]
            guard mountSucceeds(devId) else { return ProcessResult(status: 1) }
            table.add(device: "/dev/\(devId)", mountPoint: "/Volumes/CARD_\(devId)")
            return ProcessResult(status: 0)
        default:
            return ProcessResult(status: 1)
        }
    }
}

@Suite struct MountAllTests {
    @Test func talliesOutcomesAndCollectsMountedVolumes() async {
        let table = FakeMountTable()
        let mounter = makeMounter(runner: mountingRunner(table: table) { _ in true }, mountTable: table)
        let result = await mounter.mountAll(["disk4s1", "disk4s2"])
        #expect(result.counts == MountReport.Counts(ok: 2, fail: 0, skip: 0))
        #expect(result.mounted.map(\.device) == ["disk4s1", "disk4s2"])
        #expect(result.mounted.map(\.mountPoint) == ["/Volumes/CARD_disk4s1", "/Volumes/CARD_disk4s2"])
    }

    @Test func countsFailuresAndSkipsWithoutCollectingThem() async {
        let table = FakeMountTable([MountEntry(device: "/dev/disk4s1", mountPoint: "/Volumes/CARD")])
        let mounter = makeMounter(
            runner: mountingRunner(table: table) { _ in false }, mountTable: table,
            allowRawFallback: false)
        let result = await mounter.mountAll(["disk4s1", "disk4s2"])
        #expect(result.counts == MountReport.Counts(ok: 0, fail: 1, skip: 1))
        #expect(result.mounted.isEmpty)
    }
}
