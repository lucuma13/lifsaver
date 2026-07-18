// Consolidated one-file-per-subject suite:
// swiftlint:disable file_length
import Foundation
import Testing
import os

@testable import LifsaverKit

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
// isExternalHardware
// ===========================================================================

@Suite struct IsExternalHardwareTests {
    @Test func externalBusIsExternal() async {
        let runner = diskutilRunner(info: ["disk4": infoExternal])
        #expect(await makeScanner(runner: runner).isExternalHardware("disk4"))
    }

    @Test func internalFixedDiskIsNotExternal() async {
        let runner = diskutilRunner(info: ["disk0": infoInternalFixed])
        #expect(!(await makeScanner(runner: runner).isExternalHardware("disk0")))
    }

    @Test func removableMediaRescuesMisreportedInternal() async {
        // USB bridges can misreport Internal; RemovableMediaOrExternalDevice
        // is the second signal that still identifies the card reader.
        let runner = diskutilRunner(info: ["disk4": infoMisreportingBridge])
        #expect(await makeScanner(runner: runner).isExternalHardware("disk4"))
    }

    @Test func failsClosedOnMissingKeys() async {
        let runner = diskutilRunner(info: ["disk4": ["Content": "GUID_partition_scheme"]])
        #expect(!(await makeScanner(runner: runner).isExternalHardware("disk4")))
    }

    @Test func failsClosedOnDiskutilFailure() async {
        let runner = FakeProcessRunner(always: ProcessResult(status: 1))
        #expect(!(await makeScanner(runner: runner).isExternalHardware("disk4")))
    }

    @Test func failsClosedOnUnreadablePlist() async {
        let runner = FakeProcessRunner(always: ProcessResult(status: 0, stdout: Data("not a plist".utf8)))
        #expect(!(await makeScanner(runner: runner).isExternalHardware("disk4")))
    }

    @Test func retriesOnceAfterTransientQueryFailure() async {
        // diskutil is most likely to be flaky exactly when diskarbitrationd is
        // wedged on a stalled card; one transient failure must not hide it.
        let external = plistData(infoExternal)
        let attempts = OSAllocatedUnfairLock(initialState: 0)
        let runner = FakeProcessRunner { _, _ in
            let attempt = attempts.withLock { count -> Int in
                count += 1
                return count
            }
            return attempt == 1 ? ProcessResult(status: 1) : ProcessResult(status: 0, stdout: external)
        }
        #expect(await makeScanner(runner: runner).isExternalHardware("disk4"))
        #expect(attempts.withLock { $0 } == 2)
    }

    @Test func confirmedInternalIsNotRetried() async {
        // A successful query whose keys say "internal" is final.
        let runner = diskutilRunner(info: ["disk0": infoInternalFixed])
        #expect(!(await makeScanner(runner: runner).isExternalHardware("disk0")))
        #expect(runner.calls.count == 1)
    }
}

// ===========================================================================
// filterTargetPartitions
// ===========================================================================

@Suite struct FilterTargetPartitionsTests {
    @Test func picksUpUnmountedExternalExfat() async {
        let runner = diskutilRunner(info: ["disk4": infoExternal])
        let targets = await makeScanner(runner: runner)
            .filterTargetPartitions(diskutilPlistExternalExfat, activeMounts: [])
        #expect(targets == ["disk4s1"])
    }

    @Test func skipsInternalDisks() async {
        // Boot Camp scenario: an unmounted NTFS/FAT partition on the internal
        // fixed disk must never become a target.
        let runner = diskutilRunner(info: ["disk0": infoInternalFixed])
        let targets = await makeScanner(runner: runner)
            .filterTargetPartitions(diskutilPlistInternal, activeMounts: [])
        #expect(targets.isEmpty)
    }

    @Test func acceptsMisreportingBridge() async {
        let runner = diskutilRunner(info: ["disk4": infoMisreportingBridge])
        let targets = await makeScanner(runner: runner)
            .filterTargetPartitions(diskutilPlistExternalExfat, activeMounts: [])
        #expect(targets == ["disk4s1"])
    }

    @Test func failsClosedWhenExternalityUnknown() async {
        // No info response for disk4 → treated as internal.
        let targets = await makeScanner(runner: diskutilRunner())
            .filterTargetPartitions(diskutilPlistExternalExfat, activeMounts: [])
        #expect(targets.isEmpty)
    }

    @Test func skipsEFIPartition() async {
        let runner = diskutilRunner(info: ["disk4": infoExternal])
        let targets = await makeScanner(runner: runner).filterTargetPartitions(diskutilPlistEFI, activeMounts: [])
        // disk4s1 = EFI (blocked), disk4s2 = Microsoft Basic Data (allowed)
        #expect(!targets.contains("disk4s1"))
        #expect(targets.contains("disk4s2"))
    }

    @Test func skipsAppleAPFSWithoutQueryingExternality() async {
        let runner = diskutilRunner(info: ["disk4": infoExternal])
        let targets = await makeScanner(runner: runner).filterTargetPartitions(diskutilPlistAPFS, activeMounts: [])
        #expect(targets.isEmpty)
        // Content filtering alone rules the disk out — no subprocess needed.
        #expect(runner.calls.isEmpty)
    }

    @Test func skipsAlreadyMountedDevice() async {
        let captured = CapturedConsole()
        let runner = diskutilRunner(info: ["disk4": infoExternal])
        let scanner = makeScanner(runner: runner, console: captured.console, verbose: true)
        let targets = await scanner.filterTargetPartitions(diskutilPlistExternalExfat, activeMounts: ["/dev/disk4s1"])
        #expect(targets.isEmpty)
        #expect(captured.outText.contains("already mounted"))
    }

    @Test func verboseExplainsContentSkips() async {
        // Diagnostic reports replay these lines; every rejection needs a why.
        let captured = CapturedConsole()
        let runner = diskutilRunner(info: ["disk4": infoExternal])
        let scanner = makeScanner(runner: runner, console: captured.console, verbose: true)
        _ = await scanner.filterTargetPartitions(diskutilPlistEFI, activeMounts: [])
        #expect(captured.outText.contains("Skipping disk4s1 — system partition (EFI)."))

        _ = await scanner.filterTargetPartitions(
            [
                "AllDisksAndPartitions": [
                    ["DeviceIdentifier": "disk6", "Partitions": [["DeviceIdentifier": "disk6s1"]]]
                ]
            ],
            activeMounts: [])
        #expect(captured.outText.contains("Skipping disk6s1 — Content (empty) is not camera-card-like."))
    }

    @Test func contentSkipsAreSilentByDefault() async {
        let captured = CapturedConsole()
        let runner = diskutilRunner(info: ["disk4": infoExternal])
        let scanner = makeScanner(runner: runner, console: captured.console)
        _ = await scanner.filterTargetPartitions(diskutilPlistEFI, activeMounts: [])
        #expect(captured.outText.isEmpty)
    }

    @Test func alreadyMountedSkipIsSilentByDefault() async {
        let captured = CapturedConsole()
        let runner = diskutilRunner(info: ["disk4": infoExternal])
        let scanner = makeScanner(runner: runner, console: captured.console)
        let targets = await scanner.filterTargetPartitions(diskutilPlistExternalExfat, activeMounts: ["/dev/disk4s1"])
        #expect(targets.isEmpty)
        #expect(captured.outText.isEmpty)
    }

    @Test func multiDiskMultiPartition() async {
        // disk4s1=EFI(skip), disk4s2=MBD(ok), disk4s3=DOS_FAT_32(ok),
        // disk4s4=Windows_NTFS(ok — exFAT and NTFS share MBR type 0x07),
        // disk5: personality-name variants; only allowlisted spellings match
        let runner = diskutilRunner(info: ["disk4": infoExternal, "disk5": infoExternal])
        let targets = await makeScanner(runner: runner).filterTargetPartitions(diskutilPlistMulti, activeMounts: [])
        #expect(!targets.contains("disk4s1"))
        #expect(targets.contains("disk4s2"))
        #expect(targets.contains("disk4s3"))
        #expect(targets.contains("disk4s4"))
        #expect(targets.contains("disk5s1"))
        #expect(targets.contains("disk5s2"))
        #expect(!targets.contains("disk5s3"))
    }

    @Test func emptyDiskDataReturnsEmpty() async {
        let targets = await makeScanner().filterTargetPartitions(["AllDisksAndPartitions": [Any]()], activeMounts: [])
        #expect(targets.isEmpty)
    }

    @Test func partitionMissingDeviceIdentifierIsSkipped() async {
        let data: [String: Any] = [
            "AllDisksAndPartitions": [
                [
                    "DeviceIdentifier": "disk4",
                    "Partitions": [["Content": "Microsoft Basic Data"]],  // no DeviceIdentifier
                ]
            ]
        ]
        let runner = diskutilRunner(info: ["disk4": infoExternal])
        let targets = await makeScanner(runner: runner).filterTargetPartitions(data, activeMounts: [])
        #expect(targets.isEmpty)
    }

    @Test func diskMissingDeviceIdentifierIsSkipped() async {
        // Candidate partitions but no whole-disk id to verify → fail closed.
        let data: [String: Any] = [
            "AllDisksAndPartitions": [
                [
                    "Partitions": [["DeviceIdentifier": "disk4s1", "Content": "Microsoft Basic Data"]]
                ]
            ]
        ]
        let runner = diskutilRunner(info: ["disk4": infoExternal])
        let targets = await makeScanner(runner: runner).filterTargetPartitions(data, activeMounts: [])
        #expect(targets.isEmpty)
    }

    @Test(arguments: [
        "Microsoft Basic Data",
        "DOS_FAT_32",
        "Windows_FAT_32",
        "Windows_NTFS",
        "exFAT",
        "ExFAT",
    ])
    func allAllowlistedContentTypesAreAccepted(contentType: String) async {
        let data: [String: Any] = [
            "AllDisksAndPartitions": [
                [
                    "DeviceIdentifier": "disk4",
                    "Partitions": [["DeviceIdentifier": "disk4s1", "Content": contentType]],
                ]
            ]
        ]
        let runner = diskutilRunner(info: ["disk4": infoExternal])
        let targets = await makeScanner(runner: runner).filterTargetPartitions(data, activeMounts: [])
        #expect(targets.contains("disk4s1"))
    }

    @Test(arguments: [
        "Apple_APFS",
        "Apple_HFS",
        "Apple_Boot",
        "Apple_Recovery",
        "Apple_CoreStorage",
        "EFI",
    ])
    func systemContentTypesAreRejected(contentType: String) async {
        let data: [String: Any] = [
            "AllDisksAndPartitions": [
                [
                    "DeviceIdentifier": "disk4",
                    "Partitions": [["DeviceIdentifier": "disk4s1", "Content": contentType]],
                ]
            ]
        ]
        let runner = diskutilRunner(info: ["disk4": infoExternal])
        let targets = await makeScanner(runner: runner).filterTargetPartitions(data, activeMounts: [])
        #expect(targets.isEmpty)
    }

    @Test(arguments: ["Microsoft Basic Data Extra", "exFAT2", "NTFS"])
    func allowlistMatchingIsExactNotSubstring(contentType: String) async {
        // The most dangerous decision the app makes must not widen through a
        // partial match against an unexpected Content value.
        let data: [String: Any] = [
            "AllDisksAndPartitions": [
                [
                    "DeviceIdentifier": "disk4",
                    "Partitions": [["DeviceIdentifier": "disk4s1", "Content": contentType]],
                ]
            ]
        ]
        let runner = diskutilRunner(info: ["disk4": infoExternal])
        let targets = await makeScanner(runner: runner).filterTargetPartitions(data, activeMounts: [])
        #expect(targets.isEmpty)
    }

    @Test func unpartitionedSuperfloppyDiskIsATarget() async {
        // Cards formatted without a partition map put the filesystem on the
        // whole-disk node: no Partitions array, the Content sits on the disk.
        let data: [String: Any] = [
            "AllDisksAndPartitions": [
                ["DeviceIdentifier": "disk4", "Content": "Windows_FAT_32"]
            ]
        ]
        let runner = diskutilRunner(info: ["disk4": infoExternal])
        let targets = await makeScanner(runner: runner).filterTargetPartitions(data, activeMounts: [])
        #expect(targets == ["disk4"])
    }

    @Test func partitionSchemeWholeDiskIsNotATarget() async {
        // A partitioned disk whose partitions were all filtered must not fall
        // back to offering the whole-disk node.
        let data: [String: Any] = [
            "AllDisksAndPartitions": [
                [
                    "DeviceIdentifier": "disk4",
                    "Content": "GUID_partition_scheme",
                    "Partitions": [["DeviceIdentifier": "disk4s1", "Content": "EFI"]],
                ]
            ]
        ]
        let runner = diskutilRunner(info: ["disk4": infoExternal])
        let targets = await makeScanner(runner: runner).filterTargetPartitions(data, activeMounts: [])
        #expect(targets.isEmpty)
    }

    @Test func mountedSuperfloppyDiskIsSkipped() async {
        let data: [String: Any] = [
            "AllDisksAndPartitions": [
                ["DeviceIdentifier": "disk4", "Content": "Windows_FAT_32"]
            ]
        ]
        let runner = diskutilRunner(info: ["disk4": infoExternal])
        let targets = await makeScanner(runner: runner).filterTargetPartitions(data, activeMounts: ["/dev/disk4"])
        #expect(targets.isEmpty)
    }
}

// ===========================================================================
// scanTargets (scan pipeline: diskutil plist + fresh mount table)
// ===========================================================================

@Suite struct ScanTargetsTests {
    @Test func excludesDevicesAlreadyInMountTable() async throws {
        let runner = diskutilRunner(
            list: diskutilPlistMulti,
            info: ["disk4": infoExternal, "disk5": infoExternal])
        let table = FakeMountTable([MountEntry(device: "/dev/disk4s2", mountPoint: "/Volumes/CARD")])
        let targets = try await makeScanner(runner: runner, mountTable: table).scanTargets()
        #expect(!targets.contains("disk4s2"))
        #expect(targets.contains("disk4s3"))
    }

    @Test func throwsWhenMountTableUnreadable() async {
        // Guessing "nothing mounted" would offer every mounted volume as a
        // target; a scan that cannot see the table must fail loudly.
        let runner = diskutilRunner(list: diskutilPlistExternalExfat, info: ["disk4": infoExternal])
        let table = FakeMountTable(throwing: POSIXError(.EIO))
        await #expect(throws: DiskUtilError.self) {
            try await makeScanner(runner: runner, mountTable: table).scanTargets()
        }
    }
}
