import Foundation
import os

// Portable GitHub-releases update checker.
//
// Checks the repository's latest release for a newer version and prints an
// upgrade hint to stderr:
//
//     Update available! Run: brew upgrade --cask lifsaver
//
// Behaviour:
//   - never crashes or slows down the host CLI: every failure is silent,
//     and the network fetch runs in a background task that notify() waits
//     on only briefly
//   - at most one API request per `checkInterval` (result cached
//     private-to-the-user in ~/Library/Caches/<package>)
//   - `{latest}` in `upgradeCommand` is replaced with the newest known
//     version when the hint is printed (for direct download links)
//   - hints only appear on interactive runs (stderr is a tty)
//   - colour follows the NO_COLOR / FORCE_COLOR conventions (no-color.org)
//   - opt out with LIFSAVER_NO_UPDATE_CHECK=1, NO_UPDATE_CHECK=1, or in CI

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
    public init() {}

    public func fetchLatestTag(repo: String, userAgent: String, timeout: TimeInterval) async -> String? {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            return nil
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        guard
            let (data, response) = try? await URLSession.shared.data(for: request),
            let http = response as? HTTPURLResponse, http.statusCode == 200,
            data.count <= 1 << 20,
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tagName = object["tag_name"] as? String
        else { return nil }
        return tagName
    }
}

// ---------------------------------------------------------------------------
// Checker
// ---------------------------------------------------------------------------

public final class UpdateChecker: Sendable {
    let package: String
    let repo: String
    let currentVersion: String
    let upgradeCommand: String
    let checkInterval: TimeInterval
    let cacheFile: URL
    let fetcher: any LatestReleaseFetching
    let environment: [String: String]
    let stderrIsInteractive: @Sendable () -> Bool
    let emit: @Sendable (String) -> Void

    private let latestBox = OSAllocatedUnfairLock<String?>(initialState: nil)
    /// Finishes when the check settles (fetch done, cache hit, or disabled),
    /// so notify() can wait for an in-flight fetch with a hard cap.
    private let fetchSettled: AsyncStream<Void>
    private let fetchSettledContinuation: AsyncStream<Void>.Continuation

    public init(
        package: String,
        repo: String,
        currentVersion: String,
        upgradeCommand: String,
        checkInterval: TimeInterval = 24 * 60 * 60,
        cacheDirectory: URL? = nil,
        fetcher: any LatestReleaseFetching = GitHubReleaseFetcher(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        stderrIsInteractive: @escaping @Sendable () -> Bool = { isatty(STDERR_FILENO) != 0 },
        emit: (@Sendable (String) -> Void)? = nil
    ) {
        self.package = package
        self.repo = repo
        self.currentVersion = currentVersion
        self.upgradeCommand = upgradeCommand
        self.checkInterval = checkInterval
        let cacheBase =
            cacheDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches")
            .appendingPathComponent(package)
        cacheFile = cacheBase.appendingPathComponent("update-check.json")
        self.fetcher = fetcher
        self.environment = environment
        self.stderrIsInteractive = stderrIsInteractive
        self.emit = emit ?? { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
        (fetchSettled, fetchSettledContinuation) = AsyncStream.makeStream(of: Void.self)
    }

    // --- lifecycle ---------------------------------------------------------

    /// Begin the check. Instant: either reads a fresh cache or forks a fetch.
    public func start() {
        guard enabled() else {
            fetchSettledContinuation.finish()
            return
        }
        if let cached = readCache() {
            latestBox.withLock { $0 = cached }
            fetchSettledContinuation.finish()
            return
        }
        Task(priority: .utility) { [self] in
            defer { fetchSettledContinuation.finish() }
            guard
                let tag = await fetcher.fetchLatestTag(
                    repo: repo,
                    userAgent: "\(package)/\(currentVersion) (update-check)",
                    timeout: 5
                )
            else { return }
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            latestBox.withLock { $0 = version }
            writeCache(version)
        }
    }

    /// Print the upgrade hint to stderr if a newer release is known.
    ///
    /// Waits at most `timeout` seconds for an in-flight fetch — long enough
    /// for a warm connection, short enough to be imperceptible. A fetch that
    /// misses the window is simply not reported this run.
    public func notify(timeout: TimeInterval = 0.25) async {
        // Race the settle signal against a deadline; both branches respond
        // to cancellation, so the group ends as soon as either finishes.
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [fetchSettled] in
                for await _ in fetchSettled {}
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            }
            await group.next()
            group.cancelAll()
        }

        guard let known = latestBox.withLock({ $0 }), isNewer(latest: known, current: currentVersion) else { return }
        let command = upgradeCommand.replacingOccurrences(of: "{latest}", with: known)
        if stderrSupportsColor() {
            // BOLD stacks on ORANGE, so the command renders bold orange.
            emit("\u{1B}[38;5;208mUpdate available! Run: \u{1B}[1m\(command)\u{1B}[0m")
        } else {
            emit("Update available! Run: \(command)")
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

    /// Force a fresh check now, ignoring the cache and the interactive/opt-out
    /// gates that only govern the passive CLI hint — the user asked for this.
    /// Refreshes the known version and cache; the result is then reflected by
    /// `knownNewerVersion()`. For the GUI "Check for Updates" menu action.
    public func checkNow() async {
        guard
            let tag = await fetcher.fetchLatestTag(
                repo: repo,
                userAgent: "\(package)/\(currentVersion) (update-check)",
                timeout: 5
            )
        else { return }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        latestBox.withLock { $0 = version }
        writeCache(version)
    }

    // --- internals ---------------------------------------------------------

    func enabled() -> Bool {
        let prefix = package.uppercased().map { $0.isLetter || $0.isNumber ? $0 : "_" }
        let optOuts = ["\(String(prefix))_NO_UPDATE_CHECK", "NO_UPDATE_CHECK", "CI"]
        // Any non-empty value opts out — including "0" and "false" — matching
        // how CI-style flags are conventionally treated.
        if optOuts.contains(where: { !(environment[$0] ?? "").isEmpty }) {
            return false
        }
        if SemanticVersion(currentVersion) == nil {  // dev build / unknown version
            return false
        }
        return stderrIsInteractive()
    }

    func stderrSupportsColor() -> Bool {
        if !(environment["NO_COLOR"] ?? "").isEmpty { return false }
        if !(environment["FORCE_COLOR"] ?? "").isEmpty { return true }
        return stderrIsInteractive()
    }

    func readCache() -> String? {
        guard
            let data = try? Data(contentsOf: cacheFile),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let checkedAt = object["checked_at"] as? Double,
            let cachedLatest = object["latest"] as? String,
            Date().timeIntervalSince1970 - checkedAt < checkInterval
        else { return nil }
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
