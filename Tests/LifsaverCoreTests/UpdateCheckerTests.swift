import Foundation
import Testing
import os

@testable import LifsaverCore

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

final class FakeReleaseFetcher: LatestReleaseFetching {
    private let tag: String?
    private let state = OSAllocatedUnfairLock(initialState: (fetchCount: 0, lastUserAgent: String?.none))

    init(tag: String?) {
        self.tag = tag
    }

    var fetchCount: Int { state.withLock { $0.fetchCount } }
    var lastUserAgent: String? { state.withLock { $0.lastUserAgent } }

    func fetchLatestTag(repo: String, userAgent: String, timeout: TimeInterval) async -> String? {
        state.withLock {
            $0.fetchCount += 1
            $0.lastUserAgent = userAgent
        }
        return tag
    }
}

final class EmittedLines {
    private let state = OSAllocatedUnfairLock(initialState: [String]())

    var lines: [String] { state.withLock { $0 } }
    var emit: @Sendable (String) -> Void {
        { [state] line in state.withLock { $0.append(line) } }
    }
    var text: String { lines.joined(separator: "\n") }
}

private func makeChecker(
    currentVersion: String = "1.0.0",
    fetcher: FakeReleaseFetcher = FakeReleaseFetcher(tag: nil),
    environment: [String: String] = [:],
    interactive: Bool = true,
    cacheDirectory: URL,
    emitted: EmittedLines = EmittedLines(),
    checkInterval: TimeInterval = 24 * 60 * 60,
    upgradeCommand: String = "brew upgrade --cask lifsaver"
) -> UpdateChecker {
    UpdateChecker(
        package: "lifsaver",
        repo: "lucuma13/lifsaver",
        currentVersion: currentVersion,
        upgradeCommand: upgradeCommand,
        checkInterval: checkInterval,
        cacheDirectory: cacheDirectory,
        fetcher: fetcher,
        environment: environment,
        stderrIsInteractive: { interactive },
        emit: emitted.emit
    )
}

private func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("lifsaver-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// start() + notify() with a generous join window so the fetch always lands.
private func check(_ checker: UpdateChecker) async {
    checker.start()
    await checker.notify(timeout: 5)
}

// ===========================================================================
// SemanticVersion / isNewer
// ===========================================================================

@Suite struct SemanticVersionTests {
    @Test(arguments: [
        ("1.0.0", true),
        ("v1.2.3", true),
        ("0.1", true),
        ("2", true),
        ("1.2.3-beta", true),
        ("0.1.0-beta.1", true),
        ("1.2.3+build.5", true),
        ("unknown", false),
        ("", false),
        ("a.b.c", false),
        ("1..2", false),
        ("1.2.3-", false),  // trailing dash, empty pre-release
        ("1.2.3-beta..1", false),  // empty pre-release field
    ])
    func parseVersion(input: String, parses: Bool) {
        #expect((SemanticVersion(input) != nil) == parses)
    }

    @Test(arguments: [
        ("1.0.1", "1.0.0", true),
        ("1.1.0", "1.0.9", true),
        ("2.0.0", "1.9.9", true),
        ("1.0.0", "1.0.0", false),
        ("1.0.0", "1.0.1", false),
        ("1.0", "1.0.0", false),  // padded comparison: 1.0 == 1.0.0
        ("unknown", "1.0.0", false),
        ("1.0.1", "unknown", false),
        // Pre-release precedence (SemVer §11): the motivating case is a beta
        // user being nudged onto the matching stable release.
        ("0.1.0", "0.1.0-beta.1", true),  // stable outranks its pre-release
        ("0.1.0-beta.1", "0.1.0", false),  // ...and not the reverse
        ("0.1.0-beta.2", "0.1.0-beta.1", true),  // later beta is newer
        ("0.1.0-beta.1", "0.1.0-beta.1", false),  // identical pre-release
        ("0.1.0-rc.1", "0.1.0-beta.1", true),  // rc > beta (alphanumeric order)
        ("0.1.0-beta.11", "0.1.0-beta.2", true),  // numeric field, not lexical
        ("0.1.0-beta.1.1", "0.1.0-beta.1", true),  // more fields is newer
        ("1.0.0-beta.1", "1.0.0+build.9", false),  // build metadata ignored
    ])
    func newerComparison(latest: String, current: String, expected: Bool) {
        #expect(isNewer(latest: latest, current: current) == expected)
    }
}

// ===========================================================================
// Upgrade-command channel detection
// ===========================================================================

@Suite struct UpgradeCommandTests {
    @Test(arguments: ["/opt/homebrew/Caskroom/lifsaver", "/usr/local/Caskroom/lifsaver"])
    func brewCommandWhenCaskroomExists(caskroom: String) {
        let command = lifsaverUpgradeCommand(directoryExists: { $0 == caskroom })
        #expect(command == "brew upgrade --cask lifsaver")
    }

    @Test func directDownloadLinkWithoutCaskroom() {
        let command = lifsaverUpgradeCommand(directoryExists: { _ in false })
        #expect(
            command
                == "open https://github.com/lucuma13/lifsaver/releases/download/v{latest}/lifsaver_installer_macos.pkg"
        )
    }

    @Test func directoryOnDiskIsDetected() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(directoryExistsOnDisk(directory.path))
    }

    @Test func missingPathIsNotADirectory() {
        let missing = temporaryDirectory().appendingPathComponent("nope")
        #expect(!directoryExistsOnDisk(missing.path))
    }

    @Test func plainFileIsNotMistakenForACaskInstall() throws {
        // A Caskroom path occupied by a file — not a directory — must not be
        // read as a Homebrew install, or we would suggest `brew upgrade` to
        // someone who installed from the .pkg.
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("lifsaver")
        try Data("not a directory".utf8).write(to: file)
        #expect(!directoryExistsOnDisk(file.path))
    }

    @Test func notifySubstitutesLatestVersionIntoCommand() async {
        let emitted = EmittedLines()
        let checker = makeChecker(
            fetcher: FakeReleaseFetcher(tag: "v2.1.0"),
            cacheDirectory: temporaryDirectory(),
            emitted: emitted,
            upgradeCommand: lifsaverUpgradeCommand(directoryExists: { _ in false })
        )
        await check(checker)
        #expect(
            emitted.text.contains(
                "open https://github.com/lucuma13/lifsaver/releases/download/v2.1.0/lifsaver_installer_macos.pkg"
            ))
    }
}

// ===========================================================================
// Enablement / opt-outs
// ===========================================================================

@Suite struct UpdateCheckerEnablementTests {
    @Test(arguments: ["LIFSAVER_NO_UPDATE_CHECK", "NO_UPDATE_CHECK", "CI"])
    func disabledByEnvVar(variable: String) async {
        let fetcher = FakeReleaseFetcher(tag: "v9.9.9")
        let emitted = EmittedLines()
        let checker = makeChecker(
            fetcher: fetcher, environment: [variable: "1"],
            cacheDirectory: temporaryDirectory(), emitted: emitted)
        await check(checker)
        #expect(fetcher.fetchCount == 0)
        #expect(emitted.lines.isEmpty)
    }

    @Test func disabledForUnparsableVersion() async {
        let fetcher = FakeReleaseFetcher(tag: "v9.9.9")
        let checker = makeChecker(
            currentVersion: "unknown", fetcher: fetcher, cacheDirectory: temporaryDirectory())
        await check(checker)
        #expect(fetcher.fetchCount == 0)
    }

    @Test func disabledWhenStderrNotATTY() async {
        let fetcher = FakeReleaseFetcher(tag: "v9.9.9")
        let checker = makeChecker(
            fetcher: fetcher, interactive: false, cacheDirectory: temporaryDirectory())
        await check(checker)
        #expect(fetcher.fetchCount == 0)
    }
}

// ===========================================================================
// Cache behaviour
// ===========================================================================

@Suite struct UpdateCheckerCacheTests {
    @Test func freshCacheSkipsNetwork() async throws {
        let directory = temporaryDirectory()
        let payload: [String: Any] = [
            "latest": "9.9.9", "checked_at": Date().timeIntervalSince1970,
        ]
        try JSONSerialization.data(withJSONObject: payload)
            .write(to: directory.appendingPathComponent("update-check.json"))

        let fetcher = FakeReleaseFetcher(tag: "v1.0.0")
        let emitted = EmittedLines()
        let checker = makeChecker(fetcher: fetcher, cacheDirectory: directory, emitted: emitted)
        await check(checker)
        #expect(fetcher.fetchCount == 0)
        #expect(emitted.text.contains("Update available"))
    }

    @Test func staleCacheTriggersFetchAndRewrite() async throws {
        let directory = temporaryDirectory()
        let cacheFile = directory.appendingPathComponent("update-check.json")
        let stale: [String: Any] = [
            "latest": "0.0.1", "checked_at": Date().timeIntervalSince1970 - 3 * 24 * 60 * 60,
        ]
        try JSONSerialization.data(withJSONObject: stale).write(to: cacheFile)

        let fetcher = FakeReleaseFetcher(tag: "v9.9.9")
        let emitted = EmittedLines()
        let checker = makeChecker(fetcher: fetcher, cacheDirectory: directory, emitted: emitted)
        await check(checker)
        #expect(fetcher.fetchCount == 1)
        #expect(emitted.text.contains("Update available"))

        let rewritten = try JSONSerialization.jsonObject(with: Data(contentsOf: cacheFile))
        let object = try #require(rewritten as? [String: Any])
        #expect(object["latest"] as? String == "9.9.9")
    }

    @Test func cacheFileIsPrivate() async throws {
        let directory = temporaryDirectory()
        let checker = makeChecker(
            fetcher: FakeReleaseFetcher(tag: "v9.9.9"), cacheDirectory: directory)
        await check(checker)

        let attributes = try FileManager.default.attributesOfItem(
            atPath: directory.appendingPathComponent("update-check.json").path)
        let permissions = try #require(attributes[.posixPermissions] as? Int)
        #expect(permissions == 0o600)
    }

    @Test func corruptCacheIsIgnored() async throws {
        let directory = temporaryDirectory()
        try Data("not json at all {".utf8)
            .write(to: directory.appendingPathComponent("update-check.json"))

        let fetcher = FakeReleaseFetcher(tag: "v9.9.9")
        let emitted = EmittedLines()
        let checker = makeChecker(fetcher: fetcher, cacheDirectory: directory, emitted: emitted)
        await check(checker)
        #expect(fetcher.fetchCount == 1)
        #expect(emitted.text.contains("Update available"))
    }

    @Test func writeCacheFailureIsSilent() async {
        // A cache directory that cannot be created must not break the check.
        let impossible = URL(fileURLWithPath: "/dev/null/nope")
        let emitted = EmittedLines()
        let checker = makeChecker(
            fetcher: FakeReleaseFetcher(tag: "v9.9.9"), cacheDirectory: impossible,
            emitted: emitted)
        await check(checker)
        #expect(emitted.text.contains("Update available"))
    }
}

// ===========================================================================
// Notification behaviour
// ===========================================================================

@Suite struct UpdateCheckerNotifyTests {
    @Test func fetchQueriesAndNotifies() async {
        let fetcher = FakeReleaseFetcher(tag: "v9.9.9")
        let emitted = EmittedLines()
        let checker = makeChecker(
            fetcher: fetcher, cacheDirectory: temporaryDirectory(), emitted: emitted)
        await check(checker)
        #expect(fetcher.fetchCount == 1)
        #expect(fetcher.lastUserAgent == "lifsaver/1.0.0 (update-check)")
        #expect(emitted.text.contains("Update available! Run: "))
        #expect(emitted.text.contains("brew upgrade --cask lifsaver"))
    }

    @Test func noHintWhenUpToDate() async {
        let emitted = EmittedLines()
        let checker = makeChecker(
            fetcher: FakeReleaseFetcher(tag: "v1.0.0"),
            cacheDirectory: temporaryDirectory(), emitted: emitted)
        await check(checker)
        #expect(emitted.lines.isEmpty)
    }

    @Test func networkFailureIsSilent() async {
        let emitted = EmittedLines()
        let checker = makeChecker(
            fetcher: FakeReleaseFetcher(tag: nil),
            cacheDirectory: temporaryDirectory(), emitted: emitted)
        await check(checker)
        #expect(emitted.lines.isEmpty)
    }

    @Test func notifyWithoutStartStaysSilent() async {
        // notify() must not hang or hint when start() was never called.
        let emitted = EmittedLines()
        let checker = makeChecker(
            fetcher: FakeReleaseFetcher(tag: "v9.9.9"),
            cacheDirectory: temporaryDirectory(), emitted: emitted)
        await checker.notify(timeout: 0.05)
        #expect(emitted.lines.isEmpty)
    }

    @Test func hintIsColouredWhenStderrSupportsIt() async {
        let emitted = EmittedLines()
        let checker = makeChecker(
            fetcher: FakeReleaseFetcher(tag: "v9.9.9"),
            cacheDirectory: temporaryDirectory(), emitted: emitted)
        await check(checker)
        #expect(emitted.text.contains("\u{1B}[38;5;208m"))
        #expect(emitted.text.contains("\u{1B}[1m"))
    }

    @Test(
        arguments: [
            (["NO_COLOR": "1"], false),
            (["FORCE_COLOR": "1"], true),
            (["NO_COLOR": "1", "FORCE_COLOR": "1"], false),  // NO_COLOR wins
            ([:], true),  // interactive default
        ] as [([String: String], Bool)])
    func colourFollowsNoColorAndForceColor(environment: [String: String], coloured: Bool) async {
        let emitted = EmittedLines()
        let checker = makeChecker(
            fetcher: FakeReleaseFetcher(tag: "v9.9.9"), environment: environment,
            cacheDirectory: temporaryDirectory(), emitted: emitted)
        await check(checker)
        #expect(emitted.text.contains("\u{1B}[") == coloured)
    }

    @Test func knownNewerVersionForMenuSurface() async {
        let checker = makeChecker(
            fetcher: FakeReleaseFetcher(tag: "v9.9.9"), cacheDirectory: temporaryDirectory())
        await check(checker)
        #expect(checker.knownNewerVersion() == "9.9.9")

        let upToDate = makeChecker(
            fetcher: FakeReleaseFetcher(tag: "v1.0.0"), cacheDirectory: temporaryDirectory())
        await check(upToDate)
        #expect(upToDate.knownNewerVersion() == nil)
    }

    @Test func checkNowFetchesEvenWhenOptedOut() async {
        // The manual GUI check ignores the CI/opt-out gates that silence the
        // passive CLI hint — the user explicitly asked.
        let fetcher = FakeReleaseFetcher(tag: "v9.9.9")
        let checker = makeChecker(
            fetcher: fetcher, environment: ["CI": "1"], cacheDirectory: temporaryDirectory())
        await checker.checkNow()
        #expect(fetcher.fetchCount == 1)
        #expect(checker.knownNewerVersion() == "9.9.9")
    }
}
