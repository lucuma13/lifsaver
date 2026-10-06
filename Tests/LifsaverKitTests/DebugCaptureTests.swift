import Foundation
import Testing

@testable import LifsaverKit

// ===========================================================================
// Debug capture
// ===========================================================================

private struct StubError: Error {}

@Suite struct DebugCaptureTests {
    private let now = Date(timeIntervalSince1970: 1_791_000_000)

    /// "Untitled" renamed to C001 while mounted: fskitd still holds the old path.
    private let renamedSettings = FakeFSKitSettings(mounts: [("C001", "/Volumes/Untitled")])
    private let renamedTable = FakeMountTable([MountEntry(device: "/dev/disk6s1", mountPoint: "/Volumes/C001")])

    private func capturer(
        runner: FakeProcessRunner = FakeProcessRunner(),
        mountTable: any MountTableReading = FakeMountTable(),
        fskitSettings: any FSKitSettingsReading = FakeFSKitSettings()
    ) -> DebugCapturer {
        let now = self.now
        return DebugCapturer(runner: runner, mountTable: mountTable, fskitSettings: fskitSettings, now: { now })
    }

    /// Answers `log show` with `log`, the history query with `history`, and
    /// `ps` with `listing`.
    private func systemRunner(log: [String] = [], history: [String] = [], listing: String = "") -> FakeProcessRunner {
        FakeProcessRunner { executable, arguments in
            let text: String
            switch executable {
            case "log": text = (arguments.contains("1h") ? history : log).joined(separator: "\n")
            case "ps": text = listing
            default: text = ""
            }
            return ProcessResult(status: 0, stdout: Data(text.utf8))
        }
    }

    private func logShowCall(_ runner: FakeProcessRunner) -> [String]? {
        runner.calls.first { $0.executable == "log" && !$0.arguments.contains("1h") }?.arguments
    }

    // --- snapshot (always on) ---

    @Test func snapshotRecordsGhostWithItsOwner() {
        let owner = Ghost(
            record: FSKitMountRecord(
                displayName: "C001", mountedOn: "/Volumes/Untitled",
                volumeUUID: "8D2DB7E6-878B-3A9A-90DD-732E93857380"),
            ownerDevice: "disk6s1", ownerMountPoint: "/Volumes/C001")
        let capture = capturer(mountTable: renamedTable, fskitSettings: renamedSettings)
            .snapshot(trigger: .stallDetected, devices: ["disk7s1"], ghosts: [owner])

        #expect(capture.trigger == .stallDetected)
        #expect(capture.devices == ["disk7s1"])
        #expect(capture.capturedAt == ISO8601DateFormatter().string(from: now))
        #expect(capture.fskit.ghostMountPoints == ["/Volumes/Untitled"])
        #expect(capture.fskit.ghosts.first?.displayName == "C001")
        #expect(capture.fskit.ghosts.first?.ownerDevice == "disk6s1")
        #expect(capture.fskit.settings?["mounts"] != nil)
        // The log excerpts come later, off the stall's path.
        #expect(capture.unifiedLog.isEmpty)
        #expect(capture.processes.isEmpty)
    }

    @Test func snapshotRunsNoSubprocess() {
        let runner = FakeProcessRunner()
        _ = capturer(runner: runner, mountTable: renamedTable, fskitSettings: renamedSettings)
            .snapshot(trigger: .stallDetected, devices: ["disk7s1"], ghosts: [])
        #expect(runner.calls.isEmpty)
    }

    @Test func snapshotGhostWithoutResolvedOwnerHasNone() {
        let capture = capturer(mountTable: renamedTable, fskitSettings: renamedSettings)
            .snapshot(trigger: .stallDetected, devices: ["disk7s1"], ghosts: [])
        #expect(capture.fskit.ghosts.first?.ownerDevice == nil)
    }

    @Test func snapshotUnreadableSettingsDegrade() {
        let capture = capturer(fskitSettings: FakeFSKitSettings(error: StubError()))
            .snapshot(trigger: .stallDetected, devices: [], ghosts: [])
        #expect(capture.fskit.error?.hasPrefix("unavailable:") == true)
    }

    // --- logs ---

    @Test func logShowStartsJustBeforeTheCardAppeared() async {
        let runner = systemRunner()
        let appeared = now.addingTimeInterval(-60)
        let capture = await capturer(runner: runner).addingLogs(
            to: capturer().snapshot(trigger: .stallDetected, devices: ["disk7s1"], ghosts: []),
            since: appeared, daDescriptions: [:])

        let start = DebugCapturer.logTimestamp(appeared.addingTimeInterval(-DebugCapturer.logLead))
        let arguments = logShowCall(runner)
        #expect(arguments?.starts(with: ["show", "--start", start]) == true)
        #expect(arguments?.contains("--debug") == true)
        #expect(arguments?.last == DebugCapturer.unifiedLogPredicate)
        #expect(capture.logWindow == "--start \(start)")
    }

    @Test func logShowFallsBackToLastTwoMinutes() async {
        let runner = systemRunner()
        _ = await capturer(runner: runner).addingLogs(
            to: capturer().snapshot(trigger: .stallDetected, devices: [], ghosts: []), since: nil, daDescriptions: [:])
        #expect(logShowCall(runner)?.starts(with: ["show", "--last", "2m"]) == true)
    }

    @Test func logWindowIsClampedForDisksPresentAtLaunch() {
        let window = capturer().logWindow(since: now.addingTimeInterval(-6 * 60 * 60))
        #expect(window == ["--start", DebugCapturer.logTimestamp(now.addingTimeInterval(-DebugCapturer.maxLogWindow))])
    }

    @Test func predicateCoversTheDecisiveSources() {
        let predicate = DebugCapturer.unifiedLogPredicate
        for source in ["fskitd", "com.apple.fskit.exfat", "com.apple.DiskArbitration.diskarbitrationd", "fsck_msdos"] {
            #expect(predicate.contains("\"\(source)\""))
        }
        #expect(predicate.contains("hardware connection lost"))
        #expect(predicate.contains("AND NOT (process == \"diskarbitrationd\""))
    }

    @Test func excerptsAreCollected() async {
        let runner = systemRunner(
            log: ["Timestamp Ty Process", "fskitd: failed preflight: Code=516"],
            history: ["diskarbitrationd: volume path changed"],
            listing: """
                  PID STAT     ELAPSED COMMAND
                    1 Ss   10-02:11:41 /sbin/launchd
                  443 Ss   10-02:11:00 /usr/libexec/fskitd
                86504 U       00:01:00 /System/Library/ExtensionKit/E.appex/Contents/MacOS/com.apple.fskit.exfat
                32220 R          00:00 log show --predicate process IN {"fskitd"}
                """)
        let capture = await capturer(runner: runner).addingLogs(
            to: capturer().snapshot(trigger: .stallDetected, devices: ["disk7s1"], ghosts: []),
            since: nil, daDescriptions: ["disk7s1": .object(["DAVolumeName": .string("Untitled")])])

        #expect(capture.unifiedLog == ["Timestamp Ty Process", "fskitd: failed preflight: Code=516"])
        #expect(capture.ghostHistory == ["diskarbitrationd: volume path changed"])
        #expect(capture.processes.count == 3)
        #expect(capture.processes.contains { $0.contains("launchd") } == false)
        #expect(capture.processes.contains { $0.contains("log show") } == false)
        #expect(capture.processes.last?.contains(" U ") == true)
        #expect(capture.daDescriptions["disk7s1"]?["DAVolumeName"]?.stringValue == "Untitled")
    }

    @Test func fskitdLineIdentifiesTheDaemonOnly() async {
        let runner = systemRunner(
            listing: """
                  PID STARTED                      COMMAND
                  443 Sat Sep 26 17:50:20 2026     /usr/libexec/fskitd
                53520 Sun Sep 27 00:46:20 2026     /usr/libexec/fskit_agent
                """)
        let capture = await capturer(runner: runner).addingLogs(
            to: capturer().snapshot(trigger: .afterMount, devices: [], ghosts: []), since: nil, daDescriptions: [:])
        #expect(capture.fskitd == "443 Sat Sep 26 17:50:20 2026     /usr/libexec/fskitd")
    }

    @Test func longExcerptKeepsHeadAndTail() {
        let lines = (1...10).map(String.init)
        #expect(DebugCapturer.capped(lines, to: 4) == ["1", "2", "... 6 lines omitted ...", "9", "10"])
        #expect(DebugCapturer.capped(lines, to: 10) == lines)
    }

    @Test func failuresDegradeToUnavailable() async {
        let capture = await capturer(runner: FakeProcessRunner(throwing: StubError())).addingLogs(
            to: capturer().snapshot(trigger: .stallDetected, devices: [], ghosts: []), since: nil, daDescriptions: [:])
        #expect(capture.unifiedLog.first?.hasPrefix("unavailable:") == true)
        #expect(capture.ghostHistory.first?.hasPrefix("unavailable:") == true)
        #expect(capture.processes.first?.hasPrefix("unavailable:") == true)
        #expect(capture.fskitd.hasPrefix("unavailable:") == true)
    }

    @Test func logShowErrorKeepsItsReason() async {
        let runner = FakeProcessRunner(always: ProcessResult(status: 64, stderr: "log: bad predicate\n"))
        let capture = await capturer(runner: runner).addingLogs(
            to: capturer().snapshot(trigger: .stallDetected, devices: [], ghosts: []), since: nil, daDescriptions: [:])
        #expect(capture.unifiedLog == ["unavailable: 'log' exited with status 64: log: bad predicate"])
    }

    // --- Foundation values as JSON ---

    @Test func diskArbitrationValuesBecomeJSON() {
        let uuid = CFUUIDCreateFromString(nil, "8D2DB7E6-878B-3A9A-90DD-732E93857380" as CFString)
        let description: [String: Any] = [
            "DAVolumeName": "Untitled",
            "DAVolumePath": URL(fileURLWithPath: "/Volumes/Untitled"),
            "DAMediaRemovable": true,
            "DAMediaSize": 64_000_000,
            "DAVolumeUUID": uuid as Any,
            "DAMediaIcon": ["CFBundleIdentifier": "com.apple.iokit.IOStorageFamily"],
            "DAMediaBSDUnit": Data([0xAB, 0x01]),
        ]
        let json = JSONValue(foundation: description)
        #expect(json["DAVolumeName"]?.stringValue == "Untitled")
        #expect(json["DAVolumePath"]?.stringValue == "/Volumes/Untitled")
        #expect(json["DAMediaRemovable"]?.boolValue == true)
        #expect(json["DAVolumeUUID"]?.stringValue == "8D2DB7E6-878B-3A9A-90DD-732E93857380")
        #expect(json["DAMediaIcon"]?["CFBundleIdentifier"]?.stringValue == "com.apple.iokit.IOStorageFamily")
        #expect(json["DAMediaBSDUnit"]?.stringValue == "ab01")
        if case .number(let size) = json["DAMediaSize"] {
            #expect(size == 64_000_000)
        } else {
            Issue.record("size is not a number")
        }
    }
}
