import Foundation
import Testing

@testable import LifsaverCore

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
    func allBlocklistedContentTypesAreRejected(contentType: String) async {
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
}
