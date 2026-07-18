import Foundation
import Testing

@testable import LifsaverKit

// ===========================================================================
// Diagnostic report generation
// ===========================================================================

private struct StubError: Error {}

@Suite struct DiagnosticsReportTests {
    private func reporter(
        runner: FakeProcessRunner = diskutilRunner(
            list: diskutilPlistExternalExfat, info: ["disk4": infoExternal]),
        mountTable: any MountTableReading = FakeMountTable()
    ) -> DiagnosticsReporter {
        DiagnosticsReporter(runner: runner, mountTable: mountTable)
    }

    @Test func headerCarriesVersionAndPrivacyNote() async {
        let report = await reporter().generate()
        #expect(report.contains("# lifsaver diagnostic report"))
        #expect(report.contains("- version: \(lifsaverVersion)"))
        #expect(report.contains("Review it before sharing."))
    }

    @Test func scanTraceListsDetectedTargets() async {
        let report = await reporter().generate()
        #expect(report.contains("## Scan trace"))
        #expect(report.contains("target: disk4s1"))
    }

    @Test func rawDiskutilSectionsIncludeListAndPerDiskInfo() async {
        let report = await reporter().generate()
        #expect(report.contains("## diskutil list -plist"))
        #expect(report.contains("AllDisksAndPartitions"))
        #expect(report.contains("--- disk4 ---"))
        #expect(report.contains("RemovableMediaOrExternalDevice"))
    }

    @Test func mountTableEntriesAreRendered() async {
        let table = FakeMountTable([MountEntry(device: "/dev/disk4s1", mountPoint: "/Volumes/CARD")])
        let report = await reporter(mountTable: table).generate()
        #expect(report.contains("/dev/disk4s1 → /Volumes/CARD"))
    }

    @Test func userNoteAndAppEventsAreEmbedded() async {
        let report = await reporter().generate(
            userNote: "Card stayed invisible after inserting.",
            appEvents: ["2026-07-17T10:00:00Z mount attempt failed: boom"]
        )
        #expect(report.contains("Card stayed invisible after inserting."))
        #expect(report.contains("## Recent app events"))
        #expect(report.contains("mount attempt failed: boom"))
    }

    @Test func missingNoteAndEventsDegradeGracefully() async {
        let report = await reporter().generate(userNote: "  \n")
        #expect(report.contains("(not provided)"))
        #expect(!report.contains("## Recent app events"))
        #expect(!report.contains("## Live log"))
    }

    @Test func liveLogIsEmbeddedVerbatim() async {
        let report = await reporter().generate(liveLog: [
            "2026-07-17T10:00:01Z Attempting diskutil mount...",
            "--- escalated helper (root) ---",
        ])
        #expect(report.contains("## Live log"))
        #expect(report.contains("2026-07-17T10:00:01Z Attempting diskutil mount..."))
        #expect(report.contains("--- escalated helper (root) ---"))
    }

    @Test func failingCommandsNeverAbortTheReport() async {
        let runner = FakeProcessRunner(throwing: StubError())
        let report = await reporter(runner: runner, mountTable: FakeMountTable(throwing: StubError()))
            .generate(userNote: "note")
        #expect(report.contains("scan failed:"))
        #expect(report.contains("unavailable:"))
        #expect(report.contains("note"))
    }

    @Test func quietFsckProbeSaysNoneRunning() async {
        let report = await reporter().generate()
        #expect(report.contains("(none running)"))
    }

    @Test func suggestedFilenameIsSortableAndSafe() {
        let date = Date(timeIntervalSince1970: 0)
        let name = DiagnosticsReporter.suggestedFilename(for: date)
        #expect(name.hasPrefix("lifsaver-report-"))
        #expect(name.hasSuffix(".txt"))
        #expect(!name.contains(" "))
        #expect(!name.contains(":"))
    }
}

// ===========================================================================
// Support email
// ===========================================================================

@Suite struct SupportEmailTests {
    @Test func assemblesToOnePlausibleAddress() {
        #expect(lifsaverSupportEmail.hasPrefix("alterluigi"))
        #expect(lifsaverSupportEmail.contains("+debug"))
        #expect(lifsaverSupportEmail.hasSuffix(".com"))
        #expect(lifsaverSupportEmail.filter { $0 == "@" }.count == 1)
        #expect(!lifsaverSupportEmail.contains(" "))
    }

    @Test func mailtoURLIsAddressedAndPrefilled() throws {
        let url = try #require(lifsaverReportMailtoURL(reportFilename: "lifsaver-report-x.txt"))
        #expect(url.scheme == "mailto")
        let absolute = url.absoluteString
        #expect(absolute.contains("subject=lifsaver%20diagnostic%20report"))
        #expect(absolute.contains("lifsaver-report-x.txt"))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.path == lifsaverSupportEmail)
    }
}
