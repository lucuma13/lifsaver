import Foundation
import Testing

@testable import LifsaverKit

// ===========================================================================
// LiveMountTable (real getmntinfo — read-only, safe in CI)
// ===========================================================================

@Suite struct LiveMountTableTests {
    @Test func liveTableContainsRootFilesystem() throws {
        let entries = try LiveMountTable().entries()
        #expect(entries.contains { $0.mountPoint == "/" })
        #expect(entries.contains { $0.device.hasPrefix("/dev/disk") })
    }
}

// ===========================================================================
// activeMounts
// ===========================================================================

@Suite struct ActiveMountsTests {
    @Test func collectsDevEntries() throws {
        let table = FakeMountTable([
            MountEntry(device: "/dev/disk1s1", mountPoint: "/"),
            MountEntry(device: "/dev/disk3s1", mountPoint: "/Volumes/NO_NAME"),
        ])
        let result = try makeScanner(mountTable: table).activeMounts()
        #expect(result == ["/dev/disk1s1", "/dev/disk3s1"])
    }

    @Test func ignoresVirtualFilesystems() throws {
        let table = FakeMountTable([
            MountEntry(device: "devfs", mountPoint: "/dev"),
            MountEntry(device: "map auto_home", mountPoint: "/System/Volumes/Data/home"),
            MountEntry(device: "/dev/disk1s1", mountPoint: "/"),
        ])
        let result = try makeScanner(mountTable: table).activeMounts()
        #expect(result == ["/dev/disk1s1"])
    }

    @Test func throwsOnFailure() {
        // A read failure must never read as "nothing mounted" — that would turn
        // every mounted volume into a mount target.
        let table = FakeMountTable(throwing: POSIXError(.EIO))
        #expect(throws: (any Error).self) {
            try makeScanner(mountTable: table).activeMounts()
        }
    }

    @Test func returnsEmptySetOnEmptyTable() throws {
        #expect(try makeScanner(mountTable: FakeMountTable()).activeMounts().isEmpty)
    }
}

// ===========================================================================
// isCurrentlyMounted
// ===========================================================================

@Suite struct IsCurrentlyMountedTests {
    @Test func trueWhenPresent() {
        let table = FakeMountTable([MountEntry(device: "/dev/disk4s1", mountPoint: "/Volumes/X")])
        #expect(makeScanner(mountTable: table).isCurrentlyMounted("disk4s1") == true)
    }

    @Test func falseWhenAbsent() {
        let table = FakeMountTable([MountEntry(device: "/dev/disk1s1", mountPoint: "/")])
        #expect(makeScanner(mountTable: table).isCurrentlyMounted("disk4s1") == false)
    }

    @Test func nilWhenTableUnreadable() {
        // "Unknown" is a distinct answer: callers must not conflate an
        // unreadable table with "unmounted".
        let captured = CapturedConsole()
        let table = FakeMountTable(throwing: POSIXError(.EIO))
        let scanner = makeScanner(mountTable: table, console: captured.console)
        #expect(scanner.isCurrentlyMounted("disk4s1") == nil)
        #expect(captured.errText.contains("WARNING"))
    }

    @Test func alwaysTakesFreshSnapshot() {
        // Must never rely on a cached set — each call must hit the mount table.
        let table = FakeMountTable()
        let scanner = makeScanner(mountTable: table)
        _ = scanner.isCurrentlyMounted("disk4s1")
        _ = scanner.isCurrentlyMounted("disk4s1")
        #expect(table.reads == 2)
    }
}

// ===========================================================================
// mountPoint(of:)
// ===========================================================================

@Suite struct MountPointTests {
    @Test func extractsCorrectMountPoint() {
        let table = FakeMountTable([MountEntry(device: "/dev/disk4s1", mountPoint: "/Volumes/CARD")])
        #expect(makeScanner(mountTable: table).mountPoint(of: "disk4s1") == "/Volumes/CARD")
    }

    @Test func returnsEmptyStringWhenNotFound() {
        let table = FakeMountTable([MountEntry(device: "/dev/disk1s1", mountPoint: "/")])
        #expect(makeScanner(mountTable: table).mountPoint(of: "disk9s9").isEmpty)
    }

    @Test func returnsEmptyStringOnFailure() {
        let table = FakeMountTable(throwing: POSIXError(.EIO))
        #expect(makeScanner(mountTable: table).mountPoint(of: "disk4s1").isEmpty)
    }

    @Test func handlesMountPointWithSpaces() {
        let table = FakeMountTable([MountEntry(device: "/dev/disk4s1", mountPoint: "/Volumes/My Card")])
        #expect(makeScanner(mountTable: table).mountPoint(of: "disk4s1") == "/Volumes/My Card")
    }
}

// ===========================================================================
// isFsckActive
// ===========================================================================

@Suite struct IsFsckActiveTests {
    private func scanner(pgrepOutput: String, status: Int32 = 0) -> DiskScanner {
        makeScanner(runner: FakeProcessRunner(always: ProcessResult(status: status, stdout: Data(pgrepOutput.utf8))))
    }

    @Test func trueWhenFsckTargetsDevice() async {
        let output = "812 /System/Library/Filesystems/exfat.fs/Contents/Resources/fsck_exfat -y /dev/rdisk4s1\n"
        #expect(await scanner(pgrepOutput: output).isFsckActive("disk4s1"))
    }

    @Test func matchesNonRawDeviceNode() async {
        #expect(await scanner(pgrepOutput: "812 fsck_msdos -y /dev/disk4s1\n").isFsckActive("disk4s1"))
    }

    @Test func falseWhenFsckTargetsOtherDevice() async {
        #expect(!(await scanner(pgrepOutput: "812 fsck_exfat -y /dev/rdisk5s1\n").isFsckActive("disk4s1")))
    }

    @Test func noFalseMatchOnLongerIdentifier() async {
        // disk4s1 must not match a check running on disk4s10.
        #expect(!(await scanner(pgrepOutput: "812 fsck_exfat -y /dev/rdisk4s10\n").isFsckActive("disk4s1")))
    }

    @Test func noFalseMatchInsideLongerToken() async {
        // disk4s1 must not match in the middle of an unrelated word like 'mydisk4s1'.
        #expect(!(await scanner(pgrepOutput: "812 fsck_exfat -y /dev/mydisk4s1\n").isFsckActive("disk4s1")))
    }

    @Test func falseWhenNoFsckRunning() async {
        #expect(!(await scanner(pgrepOutput: "", status: 1).isFsckActive("disk4s1")))
    }

    @Test func falseOnPgrepFailure() async {
        let runner = FakeProcessRunner(
            throwing: ProcessRunnerError.launchFailed(
                command: "pgrep", underlying: CocoaError(.fileNoSuchFile)))
        #expect(!(await makeScanner(runner: runner).isFsckActive("disk4s1")))
    }
}

// ===========================================================================
// diskData
// ===========================================================================

@Suite struct DiskDataTests {
    @Test func returnsParsedPlist() async throws {
        let runner = FakeProcessRunner(
            always: ProcessResult(status: 0, stdout: plistData(diskutilPlistExternalExfat)))
        let data = try await makeScanner(runner: runner).diskData()
        #expect(data["AllDisksAndPartitions"] != nil)
    }

    @Test func throwsOnDiskutilFailure() async {
        let scanner = makeScanner(runner: FakeProcessRunner(always: ProcessResult(status: 1)))
        await #expect(throws: DiskUtilError.self) {
            try await scanner.diskData()
        }
    }

    @Test func throwsOnUnreadablePlist() async {
        let scanner = makeScanner(
            runner: FakeProcessRunner(always: ProcessResult(status: 0, stdout: Data("not a plist".utf8))))
        await #expect(throws: DiskUtilError.self) {
            try await scanner.diskData()
        }
    }
}

// ===========================================================================
// partitionFSType
// ===========================================================================

@Suite struct PartitionFSTypeTests {
    @Test func returnsFilesystemTypeLowercase() async {
        let info: [String: Any] = ["FilesystemType": "ExFAT", "Content": "Microsoft Basic Data"]
        let runner = FakeProcessRunner(always: ProcessResult(status: 0, stdout: plistData(info)))
        #expect(await makeScanner(runner: runner).partitionFSType("disk4s1") == "exfat")
    }

    @Test(arguments: [("DOS_FAT_32", "msdos"), ("Windows_FAT_32", "msdos"), ("Windows_NTFS", "windows_ntfs")])
    func fallsBackToContentWhenNoFilesystemType(content: String, expected: String) async {
        // FAT partition types map onto the token the mount path understands (so
        // mount_msdos is tried first); ambiguous types pass through.
        let info: [String: Any] = ["Content": content]
        let runner = FakeProcessRunner(always: ProcessResult(status: 0, stdout: plistData(info)))
        #expect(await makeScanner(runner: runner).partitionFSType("disk4s1") == expected)
    }

    @Test func fallsBackToContentWhenFilesystemTypeEmpty() async {
        let info: [String: Any] = ["FilesystemType": "", "Content": "DOS_FAT_32"]
        let runner = FakeProcessRunner(always: ProcessResult(status: 0, stdout: plistData(info)))
        #expect(await makeScanner(runner: runner).partitionFSType("disk4s1") == "msdos")
    }

    @Test func returnsEmptyStringOnFailure() async {
        let runner = FakeProcessRunner(
            throwing: ProcessRunnerError.launchFailed(
                command: "diskutil", underlying: CocoaError(.fileNoSuchFile)))
        #expect(await makeScanner(runner: runner).partitionFSType("disk4s1").isEmpty)
    }

    @Test func returnsEmptyStringWhenBothKeysMissing() async {
        let runner = FakeProcessRunner(
            always: ProcessResult(status: 0, stdout: plistData(["SomeOtherKey": "value"])))
        #expect(await makeScanner(runner: runner).partitionFSType("disk4s1").isEmpty)
    }
}

// ===========================================================================
// Version
// ===========================================================================

@Suite struct VersionTests {
    @Test func versionIsANonEmptySemanticVersion() {
        #expect(!lifsaverVersion.isEmpty)
        #expect(SemanticVersion(lifsaverVersion) != nil)
    }
}
