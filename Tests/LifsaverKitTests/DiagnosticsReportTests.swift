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

    @Test func metaCarriesVersionAndPrivacyNote() async {
        let meta = await reporter().generate().meta
        #expect(meta.version == lifsaverVersion)
        #expect(meta.privacyNote.contains("Review it before sharing."))
    }

    @Test func scanTraceListsDetectedTargets() async {
        let trace = await reporter().generate().scanTrace
        #expect(trace.error == nil)
        #expect(trace.targets.contains { $0.device == "disk4s1" })
    }

    @Test func diskutilSectionsAreNativeStructuredJSON() async {
        let report = await reporter().generate()
        // Parsed to native JSON, not an escaped XML blob: fields are queryable.
        #expect(report.diskutilList["AllDisksAndPartitions"] != nil)
        let disk4 = report.diskInfo.first { $0.device == "disk4" }
        #expect(disk4?.info["RemovableMediaOrExternalDevice"]?.boolValue == true)
    }

    @Test func mountTableEntriesAreCaptured() async {
        let table = FakeMountTable([MountEntry(device: "/dev/disk4s1", mountPoint: "/Volumes/CARD")])
        let report = await reporter(mountTable: table).generate()
        #expect(report.mountTableError == nil)
        #expect(report.mountTable.contains { $0.device == "/dev/disk4s1" && $0.mountPoint == "/Volumes/CARD" })
    }

    @Test func userNoteAndAppEventsAreEmbedded() async {
        let report = await reporter().generate(
            userNote: "Card stayed invisible after inserting.",
            appEvents: ["2026-07-17T10:00:00Z mount attempt failed: boom"]
        )
        #expect(report.userNote == "Card stayed invisible after inserting.")
        #expect(report.appEvents == ["2026-07-17T10:00:00Z mount attempt failed: boom"])
    }

    @Test func missingNoteAndEventsDegradeGracefully() async {
        let report = await reporter().generate(userNote: "  \n")
        #expect(report.userNote == nil)
        #expect(report.appEvents.isEmpty)
        #expect(report.liveLog.isEmpty)
    }

    @Test func liveLogIsEmbeddedVerbatim() async {
        let lines = [
            "2026-07-17T10:00:01Z Attempting diskutil mount...",
            "--- escalated helper (root) ---",
        ]
        let report = await reporter().generate(liveLog: lines)
        #expect(report.liveLog == lines)
    }

    @Test func failingCommandsNeverAbortTheReport() async {
        let runner = FakeProcessRunner(throwing: StubError())
        let report = await reporter(runner: runner, mountTable: FakeMountTable(throwing: StubError()))
            .generate(userNote: "note")
        #expect(report.scanTrace.error?.contains("scan failed:") == true)
        #expect(report.mountTableError?.contains("unavailable:") == true)
        #expect(report.userNote == "note")
    }

    @Test func quietFsckProbeYieldsNoProcesses() async {
        let report = await reporter().generate()
        #expect(report.fsckProcesses.isEmpty)
    }

    /// The report exists to be machine-parsed: its JSON must round-trip.
    @Test func jsonStringIsValidAndRoundTrips() async throws {
        let report = await reporter().generate(userNote: "note", appEvents: ["event"], liveLog: ["log"])
        let data = Data(report.jsonString().utf8)
        let decoded = try JSONDecoder().decode(DiagnosticReport.self, from: data)
        #expect(decoded.userNote == "note")
        #expect(decoded.appEvents == ["event"])
        #expect(decoded.meta.version == lifsaverVersion)
        #expect(decoded.scanTrace.targets.contains { $0.device == "disk4s1" })
    }

    @Test func suggestedFilenameIsSortableAndSafe() {
        let date = Date(timeIntervalSince1970: 0)
        let name = DiagnosticsReporter.suggestedFilename(for: date)
        #expect(name.hasPrefix("lifsaver-report-"))
        #expect(name.hasSuffix(".json"))
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
        let url = try #require(lifsaverReportMailtoURL(reportFilename: "lifsaver-report-x.json"))
        #expect(url.scheme == "mailto")
        let absolute = url.absoluteString
        #expect(absolute.contains("subject=lifsaver%20diagnostic%20report"))
        #expect(absolute.contains("lifsaver-report-x.json"))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.path == lifsaverSupportEmail)
    }
}
