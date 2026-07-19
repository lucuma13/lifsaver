import Foundation
import Testing

@testable import LifsaverKit

// ===========================================================================
// Real-world regression cases
// ===========================================================================
//
// Reconstructed from troubleshooting records: three SD cards in rotation that
// day, all factory-labelled "Untitled" (three distinct volume UUIDs in the
// diskarbitrationd logs); macOS mounted one, and another stalled with its
// device node present but absent from the mount table (diskarbitrationd:
// "unable to mount /dev/disk13s1 (status code 0x00000204)"). A later manual
// mount of the same device succeeded → /Volumes/Untitled 1. The fixtures model
// the minimal two-card collision — one mounted namesake, one stalled — which
// is the mechanism under test.
//
// Fidelity caveat: the stalled card was captured as `diskutil list` text
// (Content Windows_NTFS, name Untitled, exfat, external,
// FDisk_partition_scheme, 960 GB) — the byte-exact `diskutil info -plist` at
// the stalled instant was not logged, and the mounted sibling's identifier
// (disk4s1 at /Volumes/Untitled) comes from a later capture in the same
// session. These fixtures replay the real observed values with the collision
// assembled from those moments; they are a faithful reconstruction, not a
// byte-for-byte recording.
//
// Only detection-and-attempt is testable here: whether a real `diskutil mount`
// clears a 0x204 collision is live-hardware behaviour, and the app only shells
// out to diskutil — so these tests assert the right command is issued and its
// result handled, never touching the real tools.

/// Two-"Untitled" collision, second card stalled with a device node present.
private var untitledCollisionList: [String: Any] {
    [
        "AllDisksAndPartitions": [
            [
                "DeviceIdentifier": "disk4",
                "Partitions": [
                    ["DeviceIdentifier": "disk4s1", "Content": "Windows_NTFS"]
                ],
            ],
            [
                "DeviceIdentifier": "disk13",
                "Partitions": [
                    ["DeviceIdentifier": "disk13s1", "Content": "Windows_NTFS"]
                ],
            ],
        ]
    ]
}

private var untitledCollisionInfo: [String: [String: Any]] {
    [
        "disk4": infoExternal,
        "disk13": infoExternal,
        "disk4s1": ["FilesystemType": "exfat", "Content": "Windows_NTFS"],
        "disk13s1": ["FilesystemType": "exfat", "Content": "Windows_NTFS"],
    ]
}

/// The look-alike non-bug: only the first card ever got a device node (a
/// WebUSB client held the reader open, so the mass-storage driver never
/// attached and the second card never appeared).
private var untitledSingleCardList: [String: Any] {
    [
        "AllDisksAndPartitions": [
            [
                "DeviceIdentifier": "disk4",
                "Partitions": [
                    ["DeviceIdentifier": "disk4s1", "Content": "Windows_NTFS"]
                ],
            ]
        ]
    ]
}

/// First card mounted; the second (disk13s1) absent — the 0x204 stall.
private var stalledMountTable: FakeMountTable {
    FakeMountTable([MountEntry(device: "/dev/disk4s1", mountPoint: "/Volumes/Untitled")])
}

/// Full command surface for the collision scenario: `diskutil list`/`info`
/// answered from the reconstructed plists, pgrep from `fsckOutput`, and
/// `diskutil mount` mutating the mount table the way the real command does
/// (landing on "Untitled 1", as the real retry did).
private func collisionRunner(table: FakeMountTable, fsckOutput: String = "") -> FakeProcessRunner {
    let listData = plistData(untitledCollisionList)
    let infoData = untitledCollisionInfo.mapValues { plistData($0) }
    let emptyPlist = plistData([String: Any]())
    return FakeProcessRunner { executable, arguments in
        switch executable {
        case "pgrep":
            return ProcessResult(status: fsckOutput.isEmpty ? 1 : 0, stdout: Data(fsckOutput.utf8))
        case "diskutil" where arguments.first == "list":
            return ProcessResult(status: 0, stdout: listData)
        case "diskutil" where arguments.first == "info":
            return ProcessResult(status: 0, stdout: infoData[arguments.last ?? ""] ?? emptyPlist)
        case "diskutil" where arguments.first == "mount":
            table.add(device: "/dev/\(arguments[1])", mountPoint: "/Volumes/Untitled 1")
            return ProcessResult(status: 0)
        default:
            return ProcessResult(status: 1)
        }
    }
}

@Suite struct RealWorldCasesTests {
    @Test func stalledUntitledCollisionIsDetectedAndForceMounted() async throws {
        let table = stalledMountTable
        let runner = collisionRunner(table: table)
        let scanner = makeScanner(runner: runner, mountTable: table)

        // The stalled card is the one and only target; its mounted namesake is skipped.
        #expect(try await scanner.scanTargets() == ["disk13s1"])
        #expect(await scanner.partitionFSType("disk13s1") == "exfat")

        let mounter = makeMounter(runner: runner, mountTable: table)
        #expect(await mounter.execute("disk13s1") == .ok)
        #expect(runner.calls.contains { $0.executable == "diskutil" && $0.arguments == ["mount", "disk13s1"] })
        #expect(scanner.mountPoint(of: "disk13s1") == "/Volumes/Untitled 1")
    }

    @Test func secondCardWithoutDeviceNodeIsNotATarget() async throws {
        // Nothing exists for the app (or diskutil) to mount — the scan must
        // come back empty rather than inventing a target.
        let scanner = makeScanner(
            runner: diskutilRunner(list: untitledSingleCardList, info: untitledCollisionInfo),
            mountTable: stalledMountTable)
        #expect(try await scanner.scanTargets().isEmpty)
    }

    @Test func activeFsckOnStalledCardStandsDown() async {
        let table = stalledMountTable
        let runner = collisionRunner(table: table, fsckOutput: "812 fsck_exfat -y /dev/rdisk13s1\n")
        let mounter = makeMounter(runner: runner, mountTable: table)
        #expect(await mounter.execute("disk13s1") == .skip)
        #expect(!runner.calls.contains { $0.executable == "diskutil" && $0.arguments.first == "mount" })
    }
}
