import Foundation
import Testing
import os

@testable import LifsaverKit

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
