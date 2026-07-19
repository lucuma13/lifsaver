import Foundation
import Testing
import os

@testable import LifsaverKit

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

private func makeChecker(
    currentVersion: String = "1.0.0",
    fetcher: FakeReleaseFetcher = FakeReleaseFetcher(tag: nil),
    cacheDirectory: URL,
    checkInterval: TimeInterval = 24 * 60 * 60
) -> UpdateChecker {
    UpdateChecker(
        package: "lifsaver",
        repo: "lucuma13/lifsaver",
        currentVersion: currentVersion,
        checkInterval: checkInterval,
        cacheDirectory: cacheDirectory,
        fetcher: fetcher
    )
}

private func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("lifsaver-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// start() and wait for any background fetch to land.
private func check(_ checker: UpdateChecker) async {
    await checker.start()?.value
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
// Enablement
// ===========================================================================

@Suite struct UpdateCheckerEnablementTests {
    @Test func disabledForUnparsableVersion() async {
        let fetcher = FakeReleaseFetcher(tag: "v9.9.9")
        let checker = makeChecker(
            currentVersion: "unknown", fetcher: fetcher, cacheDirectory: temporaryDirectory())
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
        let checker = makeChecker(fetcher: fetcher, cacheDirectory: directory)
        await check(checker)
        #expect(fetcher.fetchCount == 0)
        #expect(checker.knownNewerVersion() == "9.9.9")
    }

    @Test func staleCacheTriggersFetchAndRewrite() async throws {
        let directory = temporaryDirectory()
        let cacheFile = directory.appendingPathComponent("update-check.json")
        let stale: [String: Any] = [
            "latest": "0.0.1", "checked_at": Date().timeIntervalSince1970 - 3 * 24 * 60 * 60,
        ]
        try JSONSerialization.data(withJSONObject: stale).write(to: cacheFile)

        let fetcher = FakeReleaseFetcher(tag: "v9.9.9")
        let checker = makeChecker(fetcher: fetcher, cacheDirectory: directory)
        await check(checker)
        #expect(fetcher.fetchCount == 1)
        #expect(checker.knownNewerVersion() == "9.9.9")

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

    @Test func futureTimestampReadsAsStale() async throws {
        // Clock skew (fast clock at write, NTP correction after) must not pin
        // the cache "fresh" until the wall clock catches up.
        let directory = temporaryDirectory()
        let future: [String: Any] = [
            "latest": "0.0.1", "checked_at": Date().timeIntervalSince1970 + 3 * 24 * 60 * 60,
        ]
        try JSONSerialization.data(withJSONObject: future)
            .write(to: directory.appendingPathComponent("update-check.json"))

        let fetcher = FakeReleaseFetcher(tag: "v9.9.9")
        let checker = makeChecker(fetcher: fetcher, cacheDirectory: directory)
        await check(checker)
        #expect(fetcher.fetchCount == 1)
        #expect(checker.knownNewerVersion() == "9.9.9")
    }

    @Test func corruptCacheIsIgnored() async throws {
        let directory = temporaryDirectory()
        try Data("not json at all {".utf8)
            .write(to: directory.appendingPathComponent("update-check.json"))

        let fetcher = FakeReleaseFetcher(tag: "v9.9.9")
        let checker = makeChecker(fetcher: fetcher, cacheDirectory: directory)
        await check(checker)
        #expect(fetcher.fetchCount == 1)
        #expect(checker.knownNewerVersion() == "9.9.9")
    }

    @Test func writeCacheFailureIsSilent() async {
        // A cache directory that cannot be created must not break the check.
        let impossible = URL(fileURLWithPath: "/dev/null/nope")
        let checker = makeChecker(
            fetcher: FakeReleaseFetcher(tag: "v9.9.9"), cacheDirectory: impossible)
        await check(checker)
        #expect(checker.knownNewerVersion() == "9.9.9")
    }
}

// ===========================================================================
// Check behaviour
// ===========================================================================

@Suite struct UpdateCheckerCheckTests {
    @Test func fetchQueriesAndRecordsNewerVersion() async {
        let fetcher = FakeReleaseFetcher(tag: "v9.9.9")
        let checker = makeChecker(fetcher: fetcher, cacheDirectory: temporaryDirectory())
        await check(checker)
        #expect(fetcher.fetchCount == 1)
        #expect(fetcher.lastUserAgent == "lifsaver/1.0.0 (update-check)")
        #expect(checker.knownNewerVersion() == "9.9.9")
    }

    @Test func networkFailureIsSilent() async {
        let checker = makeChecker(
            fetcher: FakeReleaseFetcher(tag: nil), cacheDirectory: temporaryDirectory())
        await check(checker)
        #expect(checker.knownNewerVersion() == nil)
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

    @Test func checkNowFetchesEvenForDevBuilds() async {
        // The manual GUI check ignores the version gate that silences the
        // passive launch check — the user explicitly asked.
        let fetcher = FakeReleaseFetcher(tag: "v9.9.9")
        let checker = makeChecker(
            currentVersion: "unknown", fetcher: fetcher, cacheDirectory: temporaryDirectory())
        _ = await checker.checkNow()
        #expect(fetcher.fetchCount == 1)
    }

    @Test func checkNowReportsUpdateAvailable() async {
        let checker = makeChecker(
            fetcher: FakeReleaseFetcher(tag: "v9.9.9"), cacheDirectory: temporaryDirectory())
        #expect(await checker.checkNow() == .updateAvailable("9.9.9"))
    }

    @Test func checkNowReportsUpToDate() async {
        let checker = makeChecker(
            fetcher: FakeReleaseFetcher(tag: "v1.0.0"), cacheDirectory: temporaryDirectory())
        #expect(await checker.checkNow() == .upToDate)
    }

    @Test func checkNowReportsFailureWhenFetchFails() async {
        // A nil fetch stands for every failure: offline, unreachable, or no
        // release published yet.
        let checker = makeChecker(
            fetcher: FakeReleaseFetcher(tag: nil), cacheDirectory: temporaryDirectory())
        #expect(await checker.checkNow() == .failed)
    }
}
