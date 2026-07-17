import Foundation
import Testing
import os

@testable import LifsaverCore
@testable import lifsaver

// ===========================================================================
// `lifsaver report` subcommand plumbing
// ===========================================================================

private struct CannedRunner: ProcessRunning {
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async throws -> ProcessResult {
        switch (executable, arguments.first) {
        case ("diskutil", "list"):
            let plist = try PropertyListSerialization.data(
                fromPropertyList: [
                    "AllDisksAndPartitions": [
                        [
                            "DeviceIdentifier": "disk4",
                            "Partitions": [["DeviceIdentifier": "disk4s1", "Content": "Microsoft Basic Data"]],
                        ]
                    ]
                ], format: .xml, options: 0)
            return ProcessResult(status: 0, stdout: plist)
        case ("diskutil", "info"):
            let plist = try PropertyListSerialization.data(
                fromPropertyList: ["Internal": false, "FilesystemType": "exfat"],
                format: .xml, options: 0)
            return ProcessResult(status: 0, stdout: plist)
        default:
            return ProcessResult(status: 1)  // pgrep: no fsck running
        }
    }
}

private struct EmptyMountTable: MountTableReading {
    func entries() throws -> [MountEntry] { [] }
}

@Suite struct ReportCLITests {
    @Test func savesOneCompleteReport() async throws {
        let written = OSAllocatedUnfairLock(initialState: [(String, URL)]())
        let emitted = OSAllocatedUnfairLock(initialState: [String]())
        let status = await ReportCLI.run(
            runner: CannedRunner(),
            mountTable: EmptyMountTable(),
            directory: URL(fileURLWithPath: "/tmp/lifsaver-test-downloads"),
            write: { contents, url in written.withLock { $0.append((contents, url)) } },
            emit: { line in emitted.withLock { $0.append(line) } },
            emitError: { _ in }
        )
        #expect(status == 0)

        let writes = written.withLock { $0 }
        #expect(writes.count == 1)
        let (report, url) = try #require(writes.first)
        #expect(url.deletingLastPathComponent().path == "/tmp/lifsaver-test-downloads")
        #expect(url.lastPathComponent.hasPrefix("lifsaver-report-"))
        #expect(report.contains("# lifsaver diagnostic report"))
        #expect(report.contains("target: disk4s1 (exfat, fsck idle)"))
        #expect(report.contains("## diskutil list -plist"))
        #expect(report.contains("--- disk4 ---"))

        // The exported-file message names the destination and the support address.
        let message = emitted.withLock { $0 }.joined(separator: "\n")
        #expect(message.contains("Diagnostic report exported to \(url.path)."))
        #expect(message.contains("email it to \(lifsaverSupportEmail)"))
        // The report itself never carries the address verbatim.
        #expect(!report.contains(lifsaverSupportEmail))
    }
}
