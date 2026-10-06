import Foundation
import Testing
import os

@testable import LifsaverKit

/// The FSKit UUID `fskitSettingsPlist` gives its first mount.
private let ownerUUID = "8D2DB7E6-878B-3A9A-90DD-732E93857380"

private func record(_ name: String, _ path: String, uuid: String = ownerUUID) -> FSKitMountRecord {
    FSKitMountRecord(displayName: name, mountedOn: path, volumeUUID: uuid)
}

/// The live reproducer: "Untitled" was mounted at /Volumes/Untitled as
/// disk6s1, renamed to A001, and another "Untitled" card (disk7s1) stalled.
private struct RenameScenario {
    let mountTable: FakeMountTable
    let runner: FakeProcessRunner
    let scanner: DiskScanner

    /// `unmount` answers `diskutil unmount`; `mountResults` answers each
    /// `diskutil mount <dev>` in turn (true = success), defaulting to success.
    init(
        settings: FakeFSKitSettings = FakeFSKitSettings(mounts: [("A001", "/Volumes/Untitled")]),
        ownerUUID: String = ownerUUID,
        stalledLabel: String = "",
        existingPaths: Set<String> = [],
        unmount: ProcessResult = ProcessResult(status: 0),
        mountResults: [String: [Bool]] = [:],
        console: Console = .standard
    ) {
        let mountTable = FakeMountTable([
            MountEntry(device: "/dev/disk3s1", mountPoint: "/"),
            MountEntry(device: "/dev/disk6s1", mountPoint: "/Volumes/A001"),
        ])
        let info: [String: Data] = [
            "disk6s1": plistData(["VolumeUUID": ownerUUID, "VolumeName": "A001"]),
            "disk7s1": plistData(["VolumeName": stalledLabel]),
        ]
        let attempts = OSAllocatedUnfairLock(initialState: mountResults)
        let mountPoints = ["disk6s1": "/Volumes/A001", "disk7s1": "/Volumes/Untitled"]
        runner = FakeProcessRunner { _, arguments in
            let device = arguments.last ?? ""
            switch arguments.first {
            case "info":
                guard let data = info[device] else { return ProcessResult(status: 1) }
                return ProcessResult(status: 0, stdout: data)
            case "unmount":
                if unmount.status == 0 { mountTable.remove(device: "/dev/\(device)") }
                return unmount
            case "mount":
                let succeeds = attempts.withLock { state -> Bool in
                    guard var queue = state[device], !queue.isEmpty else { return true }
                    let next = queue.removeFirst()
                    state[device] = queue
                    return next
                }
                guard succeeds else { return ProcessResult(status: 1, stderr: "0x204") }
                mountTable.add(device: "/dev/\(device)", mountPoint: mountPoints[device] ?? "/Volumes/\(device)")
                return ProcessResult(status: 0)
            default:
                return ProcessResult(status: 0)
            }
        }
        self.mountTable = mountTable
        scanner = makeScanner(
            runner: runner, mountTable: mountTable, fskitSettings: settings, existingPaths: existingPaths,
            console: console)
    }

    func diskutilCalls(_ verb: String) -> [String] {
        runner.calls.filter { $0.arguments.first == verb }.compactMap(\.arguments.last)
    }
}

// ===========================================================================
// Where diskarbitrationd mounts a label
// ===========================================================================

@Suite struct NextMountPathTests {
    @Test func basePathWhenFree() {
        #expect(nextMountPath(forLabel: "Untitled", exists: { _ in false }) == "/Volumes/Untitled")
    }

    @Test func firstFreeNumberedPath() {
        let taken: Set = ["/Volumes/Untitled", "/Volumes/Untitled 1"]
        #expect(nextMountPath(forLabel: "Untitled", exists: taken.contains) == "/Volumes/Untitled 2")
    }

    @Test func slashBecomesColon() {
        #expect(nextMountPath(forLabel: "A/B", exists: { _ in false }) == "/Volumes/A:B")
    }

    @Test func nilWhenEveryCandidateIsTaken() {
        #expect(nextMountPath(forLabel: "Untitled", exists: { _ in true }) == nil)
    }

    @Test func labelStripsOneNumericSuffix() {
        #expect(label(fromMountPath: "/Volumes/Untitled") == "Untitled")
        #expect(label(fromMountPath: "/Volumes/Untitled 12") == "Untitled")
        #expect(label(fromMountPath: "/Volumes/Card 2 1") == "Card 2")
        #expect(label(fromMountPath: "/Volumes/A:B 1") == "A/B")
        #expect(label(fromMountPath: "/Volumes/A001") == "A001")
        #expect(label(fromMountPath: "/Volumes/ 1") == " 1")
    }
}

// ===========================================================================
// When a ghost blocks
// ===========================================================================

@Suite struct GhostBlockingTests {
    @Test func ghostOnFreeBasePathBlocks() {
        #expect(isBlocking(record("A001", "/Volumes/Untitled"), exists: { _ in false }))
    }

    /// The tested lower-path rule: a ghost on "Untitled 1" blocks only while
    /// /Volumes/Untitled is occupied.
    @Test func numberedGhostBlocksOnlyWhileLowerPathsAreOccupied() {
        let ghost = record("A001", "/Volumes/Untitled 1")
        #expect(isBlocking(ghost, exists: { $0 == "/Volumes/Untitled" }))
        #expect(!isBlocking(ghost, exists: { _ in false }))
    }

    @Test func numberedGhostNeedsEveryLowerPathOccupied() {
        let ghost = record("A001", "/Volumes/Untitled 2")
        #expect(!isBlocking(ghost, exists: { $0 == "/Volumes/Untitled" }))
        #expect(isBlocking(ghost, exists: ["/Volumes/Untitled", "/Volumes/Untitled 1"].contains))
    }

    /// A leftover folder at the ghost's own path makes DA move on, so the
    /// ghost no longer matters.
    @Test func existingFolderAtGhostPathUnblocks() {
        #expect(!isBlocking(record("A001", "/Volumes/Untitled"), exists: { $0 == "/Volumes/Untitled" }))
    }

    @Test func pathsOutsideVolumesNeverBlock() {
        #expect(!isBlocking(record("A001", "/private/var/mnt/Untitled"), exists: { _ in false }))
    }
}

// ===========================================================================
// Owner resolution
// ===========================================================================

@Suite struct GhostOwnerTests {
    private let owner = MountedVolume(
        device: "disk6s1", mountPoint: "/Volumes/A001", volumeUUID: ownerUUID, volumeName: "A001")

    @Test func ownerMatchedByUUIDCaseInsensitively() {
        let ghost = resolveGhosts([record("A001", "/Volumes/Untitled", uuid: ownerUUID.lowercased())], volumes: [owner])
        #expect(ghost == [Ghost(record: ghost[0].record, ownerDevice: "disk6s1", ownerMountPoint: "/Volumes/A001")])
    }

    /// A clone of a mounted card gets a random FSKit UUID: fall back to names.
    @Test func ownerFallsBackToNameWhenUUIDDiffers() {
        let ghosts = resolveGhosts([record("A001", "/Volumes/Untitled", uuid: "RANDOM")], volumes: [owner])
        #expect(ghosts.first?.ownerDevice == "disk6s1")
    }

    @Test func ownerMatchedByMountPointNameWhenVolumeNameMissing() {
        let unnamed = MountedVolume(device: "disk6s1", mountPoint: "/Volumes/A001", volumeUUID: "", volumeName: "")
        let ghosts = resolveGhosts([record("A001", "/Volumes/Untitled", uuid: "RANDOM")], volumes: [unnamed])
        #expect(ghosts.first?.ownerDevice == "disk6s1")
    }

    @Test func noOwnerIsALeak() {
        let ghosts = resolveGhosts([record("A001", "/Volumes/Untitled", uuid: "RANDOM")], volumes: [])
        #expect(ghosts.first?.isLeak == true)
        #expect(ghosts.first?.ownerName == "A001")
    }

    @Test func scannerResolvesOwnerThroughDiskutil() async {
        let scenario = RenameScenario()
        let ghosts = await scenario.scanner.ghosts()
        #expect(ghosts.map(\.ownerDevice) == ["disk6s1"])
        #expect(ghosts.first?.ownerMountPoint == "/Volumes/A001")
        // Only /Volumes mounts are asked about - never the boot volume.
        #expect(scenario.diskutilCalls("info") == ["disk6s1"])
    }

    @Test func noDiskutilCallsWithoutGhosts() async {
        let scenario = RenameScenario(settings: FakeFSKitSettings())
        #expect(await scenario.scanner.ghosts().isEmpty)
        #expect(await scenario.scanner.explainStall("disk7s1") == nil)
        #expect(scenario.runner.calls.isEmpty)
    }
}

// ===========================================================================
// Explaining a specific stall
// ===========================================================================

@Suite struct StallExplanationTests {
    @Test func unlabelledCardIsExplainedByTheUntitledGhost() async {
        let explanation = await RenameScenario().scanner.explainStall("disk7s1")
        #expect(explanation?.label == "Untitled")
        #expect(explanation?.ghost.ownerDevice == "disk6s1")
        #expect(explanation?.ghost.record.mountedOn == "/Volumes/Untitled")
    }

    @Test func differentLabelIsNotExplained() async {
        #expect(await RenameScenario(stalledLabel: "EOS_DIGITAL").scanner.explainStall("disk7s1") == nil)
    }

    /// The card's real label settles a digit-suffixed name: a ghost at
    /// /Volumes/Card 2 explains a "Card 2" card.
    @Test func digitSuffixedLabelUsesTheCardsOwnLabel() async {
        let scenario = RenameScenario(
            settings: FakeFSKitSettings(mounts: [("A001", "/Volumes/Card 2")]), stalledLabel: "Card 2")
        #expect(await scenario.scanner.explainStall("disk7s1")?.label == "Card 2")
    }

    @Test func occupiedLowerPathMovesTheCardPastTheGhost() async {
        let scenario = RenameScenario(existingPaths: ["/Volumes/Untitled"])
        #expect(await scenario.scanner.explainStall("disk7s1") == nil)
    }

    @Test func unreadableDeviceIsNotExplained() async {
        #expect(await RenameScenario().scanner.explainStall("disk9s1") == nil)
    }
}

// ===========================================================================
// Mounter skips diskutil on a ghost path
// ===========================================================================

@Suite struct MounterGhostSkipTests {
    @Test func unprivilegedPassSkipsDiskutilAndFails() async {
        let captured = CapturedConsole()
        let scenario = RenameScenario(console: captured.console)
        let mounter = Mounter(scanner: scenario.scanner, fileOps: FakeFileOperations(), allowRawFallback: false)
        #expect(await mounter.execute("disk7s1") == .fail)
        #expect(scenario.diskutilCalls("mount").isEmpty)
        #expect(
            captured.outText.contains(
                "it would be refused: /Volumes/Untitled is held by \"A001\""))
    }

    @Test func rawFallbackStillRunsForMountAnyway() async {
        let scenario = RenameScenario()
        let fileOps = FakeFileOperations()
        let mounter = Mounter(scanner: scenario.scanner, fileOps: fileOps)
        // The fake raw binaries exit 0 but nothing lands in the table.
        #expect(await mounter.execute("disk7s1") == .fail)
        #expect(scenario.diskutilCalls("mount").isEmpty)
        #expect(scenario.runner.calls.contains { $0.executable == "/sbin/mount_exfat" })
        #expect(fileOps.createdPaths == ["/Volumes/Camera_Data_disk7s1"])
    }

    @Test func otherLabelsStillTryDiskutil() async {
        let scenario = RenameScenario(stalledLabel: "EOS_DIGITAL")
        let mounter = Mounter(scanner: scenario.scanner, fileOps: FakeFileOperations(), allowRawFallback: false)
        #expect(await mounter.execute("disk7s1") == .ok)
        #expect(scenario.diskutilCalls("mount") == ["disk7s1"])
    }
}

// ===========================================================================
// GhostRemounter
// ===========================================================================

@Suite struct GhostRemounterTests {
    private func remount(
        _ scenario: RenameScenario, stalled: [String] = ["disk7s1"]
    ) async -> GhostRemounter.Outcome {
        guard let ghost = await scenario.scanner.ghosts().first else {
            Issue.record("no ghost in scenario")
            return .ownerUnmountFailed("no ghost")
        }
        return await GhostRemounter(scanner: scenario.scanner, retryDelay: .zero).remount(ghost, stalled: stalled)
    }

    /// Owner down, owner back, then the stuck card - in that order, never forced.
    @Test func success() async {
        // fskitd rewrites its table once the owner remounts.
        let scenario = RenameScenario(
            settings: FakeFSKitSettings(mounts: [("A001", "/Volumes/A001"), ("Untitled", "/Volumes/Untitled")]))
        let ghost = Ghost(
            record: record("A001", "/Volumes/Untitled"), ownerDevice: "disk6s1", ownerMountPoint: "/Volumes/A001")
        let outcome = await GhostRemounter(scanner: scenario.scanner, retryDelay: .zero)
            .remount(ghost, stalled: ["disk7s1"])
        #expect(
            outcome
                == .remounted(ownerMountPoint: "/Volumes/A001", mounted: ["disk7s1"], failed: [], ghostCleared: true))
        #expect(
            scenario.runner.calls.filter { $0.arguments.first != "info" }.map(\.arguments)
                == [["unmount", "disk6s1"], ["mount", "disk6s1"], ["mount", "disk7s1"]])
    }

    @Test func busyOwnerIsLeftMounted() async {
        let refusal = ProcessResult(
            status: 1, stderr: "Volume A001 on disk6s1 failed to unmount: dissented by PID 471 (/bin/bash)")
        let scenario = RenameScenario(unmount: refusal)
        #expect(await remount(scenario) == .ownerBusy(app: "bash"))
        #expect(scenario.diskutilCalls("mount").isEmpty)
        #expect(scenario.scanner.isCurrentlyMounted("disk6s1") == true)
    }

    @Test func dissentWithoutPathNamesThePID() {
        #expect(GhostRemounter.dissentingApp(in: "failed to unmount: dissented by PID 88") == "process 88")
        #expect(GhostRemounter.dissentingApp(in: "Unmount failed for disk6s1") == nil)
    }

    @Test func otherUnmountFailureChangesNothing() async {
        let scenario = RenameScenario(unmount: ProcessResult(status: 1, stdout: Data("Unmount failed".utf8)))
        #expect(await remount(scenario) == .ownerUnmountFailed("Unmount failed"))
        #expect(scenario.diskutilCalls("mount").isEmpty)
    }

    @Test func ownerRemountIsRetriedOnce() async {
        let scenario = RenameScenario(mountResults: ["disk6s1": [false, true]])
        guard case .remounted = await remount(scenario) else {
            Issue.record("expected a remount")
            return
        }
        #expect(scenario.diskutilCalls("mount") == ["disk6s1", "disk6s1", "disk7s1"])
    }

    /// The one real risk: stop loudly, and never go on to the stalled cards.
    @Test func ownerRemountFailureIsReportedAndStops() async {
        let captured = CapturedConsole()
        let scenario = RenameScenario(mountResults: ["disk6s1": [false, false]], console: captured.console)
        #expect(await remount(scenario) == .ownerNotRemounted)
        #expect(scenario.diskutilCalls("mount") == ["disk6s1", "disk6s1"])
        #expect(captured.errText.contains("was unmounted but could not be remounted"))
    }

    @Test func stuckCardStillFailing() async {
        let scenario = RenameScenario(mountResults: ["disk7s1": [false]])
        guard case .remounted(_, let mounted, let failed, let cleared) = await remount(scenario) else {
            Issue.record("expected a remount")
            return
        }
        #expect(mounted.isEmpty)
        #expect(failed == ["disk7s1"])
        // The fake settings never change, so the ghost is still recorded.
        #expect(!cleared)
    }

    @Test func leakCannotBeRemounted() async {
        let scenario = RenameScenario()
        let outcome = await GhostRemounter(scanner: scenario.scanner)
            .remount(Ghost(record: record("A001", "/Volumes/Untitled")))
        #expect(outcome == .ownerUnmountFailed("no mounted volume owns /Volumes/Untitled"))
        #expect(scenario.runner.calls.isEmpty)
    }
}

// ===========================================================================
// Icon state and wording
// ===========================================================================

@Suite struct GhostPresentationTests {
    private let ghost = Ghost(
        record: record("A001", "/Volumes/Untitled"), ownerDevice: "disk6s1", ownerMountPoint: "/Volumes/A001")

    @Test func stalledTakesPrecedenceOverGhost() {
        #expect(MenuBarIconState.current(hasStalled: true, hasBlockingGhost: true) == .stalled)
        #expect(MenuBarIconState.current(hasStalled: false, hasBlockingGhost: true) == .ghost)
        #expect(MenuBarIconState.current(hasStalled: false, hasBlockingGhost: false) == .normal)
    }

    @Test func stallAlertOffersRemountMountAnywayAndCancel() {
        let alert = StatusMenuModel.ghostStallAlert(ghost, label: "Untitled", cardCount: 1)
        #expect(alert.buttons == ["Remount \"A001\" and Mount \"Untitled\"", "Mount Anyway", "Cancel"])
        #expect(alert.informative.contains("still holding /Volumes/Untitled"))
        #expect(StatusMenuModel.ghostStallAlert(ghost, label: "Untitled", cardCount: 2).buttons[0].hasSuffix("2 Cards"))
    }

    @Test func busyAlertNamesTheApp() {
        let atStall = StatusMenuModel.ghostRemountRefusedAlert(
            ghost, outcome: .ownerBusy(app: "bash"), offerMountAnyway: true)
        #expect(atStall?.message == "\"A001\" is in use by bash")
        #expect(atStall?.buttons == ["Mount Anyway", "Cancel"])
        let fromMenu = StatusMenuModel.ghostRemountRefusedAlert(
            ghost, outcome: .ownerBusy(app: "bash"), offerMountAnyway: false)
        #expect(fromMenu?.buttons == ["OK"])
    }

    @Test func ownerLeftUnmountedNeverOffersMountAnyway() {
        let alert = StatusMenuModel.ghostRemountRefusedAlert(
            ghost, outcome: .ownerNotRemounted, offerMountAnyway: true)
        #expect(alert?.buttons == ["OK"])
        #expect(alert?.informative == "Mount it from Disk Utility.")
    }

    @Test func notificationBodies() {
        let mounted = GhostRemounter.Outcome.remounted(
            ownerMountPoint: "/Volumes/A001", mounted: ["disk7s1"], failed: [], ghostCleared: true)
        let bare = GhostRemounter.Outcome.remounted(
            ownerMountPoint: "/Volumes/A001", mounted: [], failed: [], ghostCleared: true)
        let partial = GhostRemounter.Outcome.remounted(
            ownerMountPoint: "/Volumes/A001", mounted: [], failed: ["disk7s1"], ghostCleared: true)
        #expect(
            StatusMenuModel.ghostRemountNotificationBody(ghost, outcome: mounted, announceBareRemount: false)
                == "Remounted \"A001\" and mounted 1 card.")
        #expect(StatusMenuModel.ghostRemountNotificationBody(ghost, outcome: bare, announceBareRemount: false) == nil)
        #expect(
            StatusMenuModel.ghostRemountNotificationBody(ghost, outcome: bare, announceBareRemount: true)
                == "Remounted \"A001\".")
        #expect(
            StatusMenuModel.ghostRemountNotificationBody(ghost, outcome: partial, announceBareRemount: false)
                == "Remounted \"A001\", but 1 card still did not mount.")
    }

    @Test func eventLineFlagsAGhostThatSurvived() {
        let line = StatusMenuModel.ghostRemountEventLine(
            ghost,
            outcome: .remounted(ownerMountPoint: "/Volumes/A001", mounted: [], failed: [], ghostCleared: false))
        #expect(line.contains("disk6s1"))
        #expect(line.hasSuffix("ghost STILL PRESENT"))
    }
}
