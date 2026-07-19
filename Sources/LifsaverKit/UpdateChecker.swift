import Foundation
import os

// Portable GitHub-releases update checker.
//
// Checks the repository's latest release for a newer version and surfaces it
// through knownNewerVersion() (the app's "Update to version …" menu item).
//
// Behaviour:
//   - never crashes or slows down the host process: every failure is silent,
//     and the network fetch runs in a background task
//   - at most one API request per `checkInterval` (result cached
//     private-to-the-user in ~/Library/Caches/<package>)

// ---------------------------------------------------------------------------
// Version comparison
// ---------------------------------------------------------------------------

/// A single dot-separated field of a pre-release suffix ("beta", "1"),
/// ordered per SemVer §11: numeric fields rank below alphanumeric ones,
/// numerics compare numerically, alphanumerics compare in ASCII order.
public enum PrereleaseIdentifier: Equatable, Sendable {
    case numeric(Int)
    case alphanumeric(String)

    func compare(to other: PrereleaseIdentifier) -> ComparisonResult {
        switch (self, other) {
        case (.numeric(let left), .numeric(let right)):
            return left == right ? .orderedSame : (left < right ? .orderedAscending : .orderedDescending)
        case (.alphanumeric(let left), .alphanumeric(let right)):
            return left == right ? .orderedSame : (left < right ? .orderedAscending : .orderedDescending)
        case (.numeric, .alphanumeric):
            return .orderedAscending
        case (.alphanumeric, .numeric):
            return .orderedDescending
        }
    }
}

/// Minimal semantic version: `major.minor.patch`, optional leading "v", with
/// SemVer-compliant pre-release handling. Unparsable input yields nil —
/// "cannot compare, stay quiet".
public struct SemanticVersion: Comparable, Equatable, Sendable {
    public let components: [Int]
    /// Empty for a stable release; a stable release outranks any pre-release
    /// sharing its core ("1.2.3" > "1.2.3-beta"), per SemVer §11.
    public let prerelease: [PrereleaseIdentifier]

    public init?(_ string: String) {
        var text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") {
            text = String(text.dropFirst())
        }
        // Build metadata ("+2024") never affects precedence — discard it.
        if let plus = text.firstIndex(of: "+") {
            text = String(text[..<plus])
        }
        // Split the release core from an optional pre-release suffix.
        let parts = text.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let core = parts.first.map(String.init) ?? ""
        guard !core.isEmpty else { return nil }
        var parsed: [Int] = []
        for part in core.split(separator: ".", omittingEmptySubsequences: false) {
            guard let number = Int(part), number >= 0 else { return nil }
            parsed.append(number)
        }
        guard !parsed.isEmpty else { return nil }
        components = parsed

        guard parts.count == 2 else {
            prerelease = []
            return
        }
        guard let identifiers = Self.parsePrerelease(String(parts[1])) else { return nil }
        prerelease = identifiers
    }

    /// Parses a pre-release suffix ("beta.1") into its dot-separated
    /// identifiers per SemVer §9, or nil if malformed (empty suffix, or an
    /// empty field as in "beta..1").
    private static func parsePrerelease(_ suffix: String) -> [PrereleaseIdentifier]? {
        guard !suffix.isEmpty else { return nil }  // a trailing "-" is malformed
        var identifiers: [PrereleaseIdentifier] = []
        for field in suffix.split(separator: ".", omittingEmptySubsequences: false) {
            guard !field.isEmpty else { return nil }  // empty field ("beta..1")
            // A field is numeric only when it is all digits with no leading
            // zero; anything else ("beta", "01", "rc2") is alphanumeric.
            if let number = Int(field), number >= 0, String(number) == field {
                identifiers.append(.numeric(number))
            } else {
                identifiers.append(.alphanumeric(String(field)))
            }
        }
        return identifiers
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        // Release cores compare numerically first, zero-padding the shorter.
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        // Equal cores: a version with a pre-release ranks below one without.
        switch (lhs.prerelease.isEmpty, rhs.prerelease.isEmpty) {
        case (true, true): return false  // both stable and equal
        case (true, false): return false  // stable outranks a pre-release
        case (false, true): return true  // pre-release trails its release
        case (false, false): break
        }
        // Two pre-releases: compare shared fields, then the shorter loses.
        let shared = min(lhs.prerelease.count, rhs.prerelease.count)
        for index in 0..<shared {
            switch lhs.prerelease[index].compare(to: rhs.prerelease[index]) {
            case .orderedSame: continue
            case .orderedAscending: return true
            case .orderedDescending: return false
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}

/// True if `latest` is a strictly higher release than `current`.
/// An unparsable version on either side yields false.
func isNewer(latest: String, current: String) -> Bool {
    guard let latestVersion = SemanticVersion(latest), let currentVersion = SemanticVersion(current) else {
        return false
    }
    return latestVersion > currentVersion
}

// ---------------------------------------------------------------------------
// Release fetching seam
// ---------------------------------------------------------------------------

public protocol LatestReleaseFetching: Sendable {
    /// Return the latest release tag (e.g. "v1.2.0") or nil on any failure.
    func fetchLatestTag(repo: String, userAgent: String, timeout: TimeInterval) async -> String?
}

public struct GitHubReleaseFetcher: LatestReleaseFetching {
    /// A hostile or misbehaving server (captive portal, proxy) must not balloon
    /// memory inside a long-lived menu bar app: the body is streamed and
    /// abandoned at this cap, never buffered whole before checking.
    static let maxResponseBytes = 1 << 20

    public init() {}

    public func fetchLatestTag(repo: String, userAgent: String, timeout: TimeInterval) async -> String? {
        // Not /releases/latest: GitHub defines that as the newest release NOT
        // marked prerelease (404 when only prereleases exist), which would
        // blind the checker to this project's beta releases. The newest release
        // of any kind is the first element of /releases.
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases?per_page=1") else {
            return nil
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        guard
            let (bytes, response) = try? await URLSession.shared.bytes(for: request),
            let http = response as? HTTPURLResponse, http.statusCode == 200,
            let data = try? await Self.collect(bytes, limit: Self.maxResponseBytes),
            let releases = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
            let tagName = releases.first?["tag_name"] as? String
        else { return nil }
        return tagName
    }

    private static func collect(_ bytes: URLSession.AsyncBytes, limit: Int) async throws -> Data {
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            guard data.count <= limit else { throw URLError(.dataLengthExceedsMaximum) }
        }
        return data
    }
}

// ---------------------------------------------------------------------------
// Checker
// ---------------------------------------------------------------------------

/// Result of a user-initiated "Check for Updates". Unlike the passive launch
/// check, the manual action must always tell the user what happened.
public enum ManualCheckOutcome: Equatable, Sendable {
    /// The fetch succeeded and a strictly newer release exists.
    case updateAvailable(String)
    /// The fetch succeeded and the current version is the newest.
    case upToDate
    /// The fetch failed (offline, GitHub unreachable, no releases yet, …).
    case failed
}

public final class UpdateChecker: Sendable {
    let package: String
    let repo: String
    let currentVersion: String
    let checkInterval: TimeInterval
    let cacheFile: URL
    let fetcher: any LatestReleaseFetching

    private let latestBox = OSAllocatedUnfairLock<String?>(initialState: nil)

    public init(
        package: String,
        repo: String,
        currentVersion: String,
        checkInterval: TimeInterval = 24 * 60 * 60,
        cacheDirectory: URL? = nil,
        fetcher: any LatestReleaseFetching = GitHubReleaseFetcher()
    ) {
        self.package = package
        self.repo = repo
        self.currentVersion = currentVersion
        self.checkInterval = checkInterval
        let cacheBase =
            cacheDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches")
            .appendingPathComponent(package)
        cacheFile = cacheBase.appendingPathComponent("update-check.json")
        self.fetcher = fetcher
    }

    // --- lifecycle ---------------------------------------------------------

    /// Begin the check. Instant: either reads a fresh cache or forks a fetch,
    /// returning the fetch task so tests can await it landing.
    @discardableResult
    public func start() -> Task<Void, Never>? {
        // Dev build / unknown version: cannot compare, stay quiet.
        guard SemanticVersion(currentVersion) != nil else { return nil }
        if let cached = readCache() {
            latestBox.withLock { $0 = cached }
            return nil
        }
        return Task(priority: .utility) { [self] in
            await refresh()
        }
    }

    /// The newest known release version, from cache or a finished fetch —
    /// nil when up to date or unknown. For GUI surfaces (menu items).
    public func knownNewerVersion() -> String? {
        guard let known = latestBox.withLock({ $0 }), isNewer(latest: known, current: currentVersion) else {
            return nil
        }
        return known
    }

    /// Force a fresh check now, ignoring the cache and the version gate that
    /// only governs the passive launch check — the user asked for this.
    /// Refreshes the known version and cache and reports the outcome so the GUI
    /// can acknowledge the manual "Check for Updates" action; a newer version
    /// is also reflected by `knownNewerVersion()`.
    public func checkNow() async -> ManualCheckOutcome {
        guard await refresh() else { return .failed }
        if let newer = knownNewerVersion() { return .updateAvailable(newer) }
        return .upToDate
    }

    // --- internals ---------------------------------------------------------

    /// Fetch the newest release tag, normalize it, and publish it to both the
    /// in-memory box and the on-disk cache. Single body shared by the passive
    /// launch check and the manual menu check so the two can never drift.
    /// Returns whether the fetch succeeded; the passive path ignores it.
    @discardableResult
    private func refresh() async -> Bool {
        guard
            let tag = await fetcher.fetchLatestTag(
                repo: repo,
                userAgent: "\(package)/\(currentVersion) (update-check)",
                timeout: 5
            )
        else { return false }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        latestBox.withLock { $0 = version }
        writeCache(version)
        return true
    }

    func readCache() -> String? {
        guard
            let data = try? Data(contentsOf: cacheFile),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let checkedAt = object["checked_at"] as? Double,
            let cachedLatest = object["latest"] as? String
        else { return nil }
        // A future checked_at (clock skew, NTP jump) must read as stale, not as
        // "fresh until the wall clock catches up".
        let elapsed = Date().timeIntervalSince1970 - checkedAt
        guard elapsed >= 0, elapsed < checkInterval else { return nil }
        return cachedLatest
    }

    func writeCache(_ version: String) {
        // Caching is best-effort; write-then-rename so a concurrent reader
        // never sees a torn file.
        do {
            let directory = cacheFile.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let payload = try JSONSerialization.data(withJSONObject: [
                "latest": version,
                "checked_at": Date().timeIntervalSince1970,
            ])
            let temporary = directory.appendingPathComponent("update-check.tmp.\(getpid())")
            try payload.write(to: temporary)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: temporary.path
            )
            _ = try FileManager.default.replaceItemAt(cacheFile, withItemAt: temporary)
        } catch {
            // best-effort
        }
    }
}
