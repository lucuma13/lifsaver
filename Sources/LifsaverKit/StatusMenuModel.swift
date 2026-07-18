/// Result of the menu bar app's escalated mount pass, decoupled from the
/// escalation mechanism so presentation logic on top of it is testable here.
public enum EscalatedMountOutcome: Equatable, Sendable {
    case report(MountReport.Counts)
    case cancelled
    case error(String)
}

/// Invalidates in-flight scan results once a newer scan has started.
public struct ScanGeneration: Sendable {
    private var current = 0

    public init() {}

    /// Marks the start of a new scan and returns its token.
    public mutating func begin() -> Int {
        current += 1
        return current
    }

    /// True while `token` still belongs to the most recently started scan.
    public func isCurrent(_ token: Int) -> Bool {
        token == current
    }
}

/// Tracks which stalled volumes the user has already been alerted about, so
/// the background disk watcher notifies once per card, not once per rescan.
public struct StalledWatchState: Sendable {
    private var known: Set<String> = []

    public init() {}

    /// Records the latest scan result and returns the devIds that are newly
    /// stalled, in scan order. A device that leaves the stalled set (mounted
    /// or unplugged) is forgotten, so it alerts again if it stalls anew.
    public mutating func update(stalled: [String]) -> [String] {
        let fresh = stalled.filter { !known.contains($0) }
        known = Set(stalled)
        return fresh
    }

    /// True while any volume is known to be stalled — drives the menu bar
    /// icon's attention badge.
    public var hasStalled: Bool { !known.isEmpty }
}

/// Pure presentation logic for the status-bar menu and mount notifications.
/// The app renders these values into AppKit; keeping the decisions here lets
/// them be unit tested without a window server.
public enum StatusMenuModel {
    public struct ScanTarget: Equatable, Sendable {
        public let devId: String
        public let fsType: String

        public init(devId: String, fsType: String) {
            self.devId = devId
            self.fsType = fsType
        }

        /// "disk4s1 — msdos", or just the device when the fs type is unknown.
        public var detail: String {
            fsType.isEmpty ? devId : "\(devId) — \(fsType)"
        }
    }

    public enum ScanState: Equatable, Sendable {
        case scanning
        case failed
        case results([ScanTarget])
    }

    public enum Entry: Equatable, Sendable {
        case disabled(String)
        case mount(title: String)
        case separator
        case checkForUpdates(title: String)
        case updateAvailable(title: String)
        case launchAtLogin(enabled: Bool)
        case saveReport(title: String)
        case quit(title: String)
    }

    public static func entries(
        state: ScanState,
        newerVersion: String?,
        isCheckingForUpdates: Bool = false,
        showLaunchAtLogin: Bool,
        launchAtLoginEnabled: Bool
    ) -> [Entry] {
        var entries: [Entry] = []

        switch state {
        case .scanning:
            entries.append(.disabled("Scanning…"))
        case .failed:
            entries.append(.disabled("Scan failed"))
        case .results(let targets) where targets.isEmpty:
            entries.append(.disabled("No stalled volumes detected"))
        case .results(let targets):
            let noun = targets.count == 1 ? "volume" : "volumes"
            entries.append(.mount(title: "Mount \(targets.count) stalled \(noun)"))
        }

        entries.append(.separator)

        if showLaunchAtLogin {
            entries.append(.launchAtLogin(enabled: launchAtLoginEnabled))
        }
        // Always present — reports are most needed exactly when scans fail.
        entries.append(.saveReport(title: "Send Diagnostic Report"))
        // The update item is always present, kept second-to-last: it opens the
        // latest installer once a newer version is known, otherwise it triggers
        // a manual check on click.
        if let newerVersion {
            entries.append(.updateAvailable(title: "Update to version \(newerVersion)"))
        } else if isCheckingForUpdates {
            entries.append(.disabled("Checking for Updates…"))
        } else {
            entries.append(.checkForUpdates(title: "Check for Updates"))
        }
        entries.append(.quit(title: "Quit"))

        return entries
    }

    /// Body of the proactive "a volume appeared but never mounted"
    /// notification, or nil when nothing is newly stalled.
    public static func stalledNotificationBody(newCount: Int) -> String? {
        guard newCount > 0 else { return nil }
        if newCount == 1 {
            return "Stalled volume detected"
        }
        return "\(newCount) stalled volumes detected"
    }

    /// One line for the diagnostic report's event log. It keeps the raw
    /// error text and records cancellations.
    public static func mountEventLine(for outcome: EscalatedMountOutcome) -> String {
        switch outcome {
        case .cancelled:
            return "mount attempt cancelled at the password dialog"
        case .error(let message):
            return "mount attempt failed: \(message)"
        case .report(let counts):
            return "mount attempt finished: \(counts.ok) mounted, \(counts.fail) failed, \(counts.skip) skipped"
        }
    }

    /// One line for the diagnostic report's event log, recording what the
    /// unprivileged first pass managed on its own. `fail` here is not a real
    /// failure — those volumes go on to the escalated pass.
    public static func unprivilegedMountEventLine(for counts: MountReport.Counts) -> String {
        "unprivileged mount pass: \(counts.ok) mounted, \(counts.fail) need elevation, \(counts.skip) skipped"
    }

    /// Folds the app's two mount passes into the single outcome the user is
    /// told about.
    ///
    /// The escalated pass rescans as root, so volumes the unprivileged pass
    /// already mounted are gone from its targets: its successes are added here,
    /// while the first pass's failures and skips were re-evaluated under root
    /// and are the escalated counts' to report.
    ///
    /// `escalated` is nil when the first pass left nothing for root to do.
    public static func combinedOutcome(
        unprivileged: MountReport.Counts,
        escalated: EscalatedMountOutcome?
    ) -> EscalatedMountOutcome {
        guard let escalated else { return .report(unprivileged) }
        switch escalated {
        case .report(let counts):
            return .report(.init(ok: unprivileged.ok + counts.ok, fail: counts.fail, skip: counts.skip))
        case .cancelled:
            // Dismissing the dialog declines the rest rather than failing at
            // it; whatever mounted before the prompt still counts.
            guard unprivileged.ok > 0 else { return .cancelled }
            return .report(.init(ok: unprivileged.ok))
        case .error:
            // The escalation never ran, so the first pass's failures stand.
            guard unprivileged.ok > 0 else { return escalated }
            return .report(.init(ok: unprivileged.ok, fail: unprivileged.fail))
        }
    }

    /// Body of the user-facing notification for a finished mount attempt, or
    /// nil when the outcome warrants none (user dismissed the password dialog).
    public static func notificationBody(for outcome: EscalatedMountOutcome) -> String? {
        switch outcome {
        case .cancelled:
            return nil
        case .report(let counts):
            if counts.fail > 0 {
                return "Mount failed"
            }
            if counts.ok > 0 {
                let noun = counts.ok == 1 ? "volume" : "volumes"
                return "Mounted \(counts.ok) \(noun)."
            }
            return "Nothing mounted — volumes were skipped (already mounted or being checked)."
        case .error:
            return "Mount failed"
        }
    }
}
