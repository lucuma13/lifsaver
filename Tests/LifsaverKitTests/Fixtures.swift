import Foundation
import os

@testable import LifsaverKit

// ---------------------------------------------------------------------------
// Fake process runner
// ---------------------------------------------------------------------------

/// Test double standing in for subprocess execution: a handler inspects the
/// command and returns a canned result (or throws).
final class FakeProcessRunner: ProcessRunning {
    struct Call: Sendable {
        let executable: String
        let arguments: [String]
    }

    private let handler: @Sendable (String, [String]) throws -> ProcessResult
    private let recorded = OSAllocatedUnfairLock(initialState: [Call]())

    var calls: [Call] { recorded.withLock { $0 } }

    init(
        handler: @escaping @Sendable (String, [String]) throws -> ProcessResult = { _, _ in ProcessResult(status: 0) }
    ) {
        self.handler = handler
    }

    /// Runner that returns the same result for every command.
    convenience init(always result: ProcessResult) {
        self.init(handler: { _, _ in result })
    }

    /// Runner whose every call throws, simulating OSError.
    convenience init(throwing error: any Error & Sendable) {
        self.init(handler: { _, _ in throw error })
    }

    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async throws -> ProcessResult {
        recorded.withLock { $0.append(Call(executable: executable, arguments: arguments)) }
        return try handler(executable, arguments)
    }
}

// ---------------------------------------------------------------------------
// Fake mount table
// ---------------------------------------------------------------------------

/// In-memory stand-in for the kernel mount table; mutable so mount scenarios
/// can make a device "appear" after a successful mount command.
final class FakeMountTable: MountTableReading {
    private let state = OSAllocatedUnfairLock(initialState: (entries: [MountEntry](), reads: 0))
    private let error: (any Error & Sendable)?

    init(_ entries: [MountEntry] = []) {
        state.withLock { $0.entries = entries }
        error = nil
    }

    init(throwing error: any Error & Sendable) {
        self.error = error
    }

    /// How many fresh snapshots callers have taken.
    var reads: Int { state.withLock { $0.reads } }

    func add(device: String, mountPoint: String) {
        state.withLock { $0.entries.append(MountEntry(device: device, mountPoint: mountPoint)) }
    }

    func entries() throws -> [MountEntry] {
        if let error { throw error }
        return state.withLock {
            $0.reads += 1
            return $0.entries
        }
    }
}

// ---------------------------------------------------------------------------
// Scanner factory
// ---------------------------------------------------------------------------

func makeScanner(
    runner: FakeProcessRunner = FakeProcessRunner(),
    mountTable: any MountTableReading = FakeMountTable(),
    console: Console = .standard,
    verbose: Bool = false
) -> DiskScanner {
    DiskScanner(runner: runner, mountTable: mountTable, console: console, verbose: verbose)
}

/// Console capturing output for assertions.
/// The sinks live in a locked box because Console closures are @Sendable.
final class CapturedConsole {
    private let lines = OSAllocatedUnfairLock(initialState: (out: [String](), err: [String]()))

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

func plistData(_ object: Any) -> Data {
    // swiftlint:disable:next force_try
    try! PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
}

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

// `diskutil list -plist` per-disk entries carry NO hardware-location key
// (only Content / DeviceIdentifier / OSInternal / Size); externality comes
// from a per-disk `diskutil info -plist` call. These list fixtures mirror
// that, and `diskutilRunner` supplies the matching info responses.

var diskutilPlistExternalExfat: [String: Any] {
    [
        "AllDisksAndPartitions": [
            [
                "DeviceIdentifier": "disk4",
                "Partitions": [
                    ["DeviceIdentifier": "disk4s1", "Content": "Microsoft Basic Data"]
                ],
            ]
        ]
    ]
}

var diskutilPlistInternal: [String: Any] {
    [
        "AllDisksAndPartitions": [
            [
                "DeviceIdentifier": "disk0",
                "Partitions": [
                    ["DeviceIdentifier": "disk0s1", "Content": "Microsoft Basic Data"]
                ],
            ]
        ]
    ]
}

var diskutilPlistEFI: [String: Any] {
    [
        "AllDisksAndPartitions": [
            [
                "DeviceIdentifier": "disk4",
                "Partitions": [
                    ["DeviceIdentifier": "disk4s1", "Content": "EFI"],
                    ["DeviceIdentifier": "disk4s2", "Content": "Microsoft Basic Data"],
                ],
            ]
        ]
    ]
}

var diskutilPlistAPFS: [String: Any] {
    [
        "AllDisksAndPartitions": [
            [
                "DeviceIdentifier": "disk4",
                "Partitions": [
                    ["DeviceIdentifier": "disk4s1", "Content": "Apple_APFS"]
                ],
            ]
        ]
    ]
}

var diskutilPlistMulti: [String: Any] {
    [
        "AllDisksAndPartitions": [
            [
                "DeviceIdentifier": "disk4",
                "Partitions": [
                    ["DeviceIdentifier": "disk4s1", "Content": "EFI"],
                    ["DeviceIdentifier": "disk4s2", "Content": "Microsoft Basic Data"],
                    ["DeviceIdentifier": "disk4s3", "Content": "DOS_FAT_32"],
                    ["DeviceIdentifier": "disk4s4", "Content": "Windows_NTFS"],
                ],
            ],
            [
                "DeviceIdentifier": "disk5",
                "Partitions": [
                    ["DeviceIdentifier": "disk5s1", "Content": "exFAT"],
                    ["DeviceIdentifier": "disk5s2", "Content": "ExFAT"],
                    ["DeviceIdentifier": "disk5s3", "Content": "exfat"],
                ],
            ],
        ]
    ]
}

// `diskutil info -plist <disk>` externality signals.

/// Ordinary external card reader.
var infoExternal: [String: Any] { ["Internal": false, "RemovableMediaOrExternalDevice": true] }

/// Internal fixed disk (e.g. the boot SSD hosting a Boot Camp partition).
var infoInternalFixed: [String: Any] { ["Internal": true, "RemovableMediaOrExternalDevice": false] }

/// USB bridge misreporting `Internal`; the removable-media signal rescues it.
var infoMisreportingBridge: [String: Any] { ["Internal": true, "RemovableMediaOrExternalDevice": true] }

/// Runner answering `diskutil list -plist` from `list` and
/// `diskutil info -plist <disk>` from `info`. Disks absent from `info` get an
/// empty plist, which the scanner must treat as internal (fail closed).
func diskutilRunner(list: [String: Any] = [:], info: [String: [String: Any]] = [:]) -> FakeProcessRunner {
    // Serialized up front: Data is Sendable, plist dictionaries are not.
    let listData = plistData(list)
    let infoData = info.mapValues { plistData($0) }
    let emptyPlist = plistData([String: Any]())
    return FakeProcessRunner { _, arguments in
        switch arguments.first {
        case "list":
            return ProcessResult(status: 0, stdout: listData)
        case "info":
            return ProcessResult(status: 0, stdout: infoData[arguments.last ?? ""] ?? emptyPlist)
        default:
            return ProcessResult(status: 0)
        }
    }
}
