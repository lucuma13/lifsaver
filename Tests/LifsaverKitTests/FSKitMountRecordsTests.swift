import Foundation
import Testing

@testable import LifsaverKit

// ===========================================================================
// fskitd mount records and ghost paths (the 0x204 stall)
// ===========================================================================

@Suite struct FSKitMountRecordsTests {
    @Test func parsesMountsFromLiveShapedSettings() throws {
        let data = fskitSettingsPlist(mounts: [("A001", "/Volumes/Untitled")])
        let records = try FSKitMountRecord.parse(data)
        #expect(
            records == [
                FSKitMountRecord(
                    displayName: "A001", mountedOn: "/Volumes/Untitled",
                    volumeUUID: "8D2DB7E6-878B-3A9A-90DD-732E93857380")
            ])
    }

    @Test func entriesWithoutAPathAreSkipped() throws {
        let data = plistData(["mounts": [["displayName": "Untitled"], ["mountedOn": ""]]])
        #expect(try FSKitMountRecord.parse(data).isEmpty)
    }

    @Test func unreadablePlistThrows() {
        #expect(throws: FSKitSettingsError.self) {
            try FSKitMountRecord.parse(Data("not a plist".utf8))
        }
    }

    @Test func absentSettingsMeanNoRecords() throws {
        #expect(try FakeFSKitSettings().records().isEmpty)
    }

    @Test func settingsFileReadsFromDiskAndToleratesAbsence() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("lifsaver-settings-\(UUID().uuidString).plist").path
        let file = LivefsdSettingsFile(path: path)
        #expect(try file.settingsData() == nil)

        try fskitSettingsPlist(mounts: [("Untitled", "/Volumes/Untitled")]).write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(try file.records().map(\.mountedOn) == ["/Volumes/Untitled"])
    }

    @Test func ghostIsARecordWhosePathIsNotAMountPoint() {
        let records = [
            FSKitMountRecord(displayName: "A001", mountedOn: "/Volumes/Untitled", volumeUUID: "A"),
            FSKitMountRecord(displayName: "Untitled", mountedOn: "/Volumes/Untitled 1", volumeUUID: "B"),
        ]
        let table = [
            MountEntry(device: "/dev/disk6s1", mountPoint: "/Volumes/A001"),
            MountEntry(device: "/dev/disk7s1", mountPoint: "/Volumes/Untitled 1"),
        ]
        #expect(ghostRecords(records, mountTable: table).map(\.mountedOn) == ["/Volumes/Untitled"])
    }

    // --- scanner integration -------------------------------------------------

    private let runner = diskutilRunner(list: diskutilPlistExternalExfat, info: ["disk4": infoExternal])
    private let renamedCardSettings = FakeFSKitSettings(mounts: [("A001", "/Volumes/Untitled")])
    private let renamedCardTable = FakeMountTable([MountEntry(device: "/dev/disk6s1", mountPoint: "/Volumes/A001")])

    @Test func scanWithStalledTargetNamesTheGhostPath() async throws {
        let captured = CapturedConsole()
        let scanner = makeScanner(
            runner: runner, mountTable: renamedCardTable, fskitSettings: renamedCardSettings,
            console: captured.console)
        #expect(try await scanner.scanTargets() == ["disk4s1"])
        #expect(captured.outText.contains("fskitd still reserves /Volumes/Untitled for \"A001\""))
    }

    @Test func scanWithoutTargetsStaysQuiet() async throws {
        let captured = CapturedConsole()
        let scanner = makeScanner(
            runner: diskutilRunner(list: diskutilPlistInternal), mountTable: renamedCardTable,
            fskitSettings: renamedCardSettings, console: captured.console)
        #expect(try await scanner.scanTargets().isEmpty)
        #expect(captured.out.isEmpty)
    }

    @Test func healthyRecordsAreNotReported() async throws {
        let captured = CapturedConsole()
        let table = FakeMountTable([MountEntry(device: "/dev/disk6s1", mountPoint: "/Volumes/Untitled")])
        let settings = FakeFSKitSettings(mounts: [("Untitled", "/Volumes/Untitled")])
        let scanner = makeScanner(
            runner: runner, mountTable: table, fskitSettings: settings, console: captured.console)
        #expect(try await scanner.scanTargets() == ["disk4s1"])
        #expect(captured.out.isEmpty)
    }

    @Test func unreadableSettingsNeverFailTheScan() async throws {
        struct StubError: Error {}
        let scanner = makeScanner(
            runner: runner, mountTable: renamedCardTable, fskitSettings: FakeFSKitSettings(error: StubError()))
        #expect(try await scanner.scanTargets() == ["disk4s1"])
        #expect(scanner.ghostFSKitMounts().isEmpty)
    }
}
