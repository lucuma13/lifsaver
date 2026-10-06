/// Result of the menu bar app's escalated mount pass, decoupled from the
/// escalation mechanism so presentation logic on top of it is testable here.
public enum EscalatedMountOutcome: Equatable, Sendable {
    case report(MountReport.Counts)
    case cancelled
    case error(String)
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

    /// True while any volume is known to be stalled - drives the menu bar
    /// icon's attention badge.
    public var hasStalled: Bool { !known.isEmpty }
}

/// What the menu bar icon signals, most urgent first.
public enum MenuBarIconState: Equatable, Sendable {
    /// A card stalled: the orange buoy, turned 45°.
    case stalled
    /// No card stalled yet, but a ghost would refuse the next one: a
    /// notification dot.
    case ghost
    case normal

    public static func current(hasStalled: Bool, hasBlockingGhost: Bool) -> MenuBarIconState {
        if hasStalled { return .stalled }
        return hasBlockingGhost ? .ghost : .normal
    }
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

        /// "disk4s1 - msdos", or just the device when the fs type is unknown.
        public var detail: String {
            fsType.isEmpty ? devId : "\(devId) - \(fsType)"
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
        /// Remount the renamed card owning a blocking ghost.
        case remountGhost(title: String, ownerDevice: String)
        case separator
        case checkForUpdates(title: String)
        case updateAvailable(title: String)
        /// The "Settings" submenu. `showStartAtLogin` is false on unbundled
        /// dev runs, where SMAppService has no bundle to register.
        case moreOptions(
            showStartAtLogin: Bool, startAtLoginEnabled: Bool, automaticUpdatesEnabled: Bool,
            remountAfterRenameEnabled: Bool)
        case saveReport(title: String)
        case quit(title: String)
    }

    // swiftlint:disable:next function_parameter_count
    public static func entries(
        state: ScanState,
        newerVersion: String?,
        showLaunchAtLogin: Bool,
        launchAtLoginEnabled: Bool,
        automaticUpdatesEnabled: Bool,
        blockingGhosts: [Ghost],
        remountAfterRenameEnabled: Bool
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

        for ghost in blockingGhosts {
            if let owner = ghost.ownerDevice {
                entries.append(.remountGhost(title: ghostMenuTitle(ghost), ownerDevice: owner))
            } else {
                entries.append(
                    .disabled("macOS still reserves \(ghost.record.mountedOn) - restart the Mac to free it"))
            }
        }

        entries.append(.separator)

        // Always present - reports are most needed exactly when scans fail.
        entries.append(.saveReport(title: "Send Diagnostic Report"))
        // The update item is always present: it opens the latest installer once
        // a newer version is known, otherwise it triggers a manual check on
        // click. The check's own progress and result are shown in an alert, not
        // the menu, which closes the instant the item is clicked.
        if let newerVersion {
            entries.append(.updateAvailable(title: "Update to version \(newerVersion)"))
        } else {
            entries.append(.checkForUpdates(title: "Check for Updates"))
        }
        entries.append(
            .moreOptions(
                showStartAtLogin: showLaunchAtLogin,
                startAtLoginEnabled: launchAtLoginEnabled,
                automaticUpdatesEnabled: automaticUpdatesEnabled,
                remountAfterRenameEnabled: remountAfterRenameEnabled))
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
    /// failure - those volumes go on to the escalated pass.
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
            // Declining the dialog leaves the remaining volumes unmounted -
            // that is a failure of the mount attempt, reported alongside
            // whatever mounted before the prompt.
            return .report(.init(ok: unprivileged.ok, fail: unprivileged.fail))
        case .error:
            // The escalation never ran, so the first pass's failures stand.
            guard unprivileged.ok > 0 else { return escalated }
            return .report(.init(ok: unprivileged.ok, fail: unprivileged.fail))
        }
    }

    /// Body of the user-facing notification for a finished mount attempt, or
    /// nil when the outcome warrants none.
    public static func notificationBody(for outcome: EscalatedMountOutcome) -> String? {
        switch outcome {
        case .cancelled:
            // Unreachable from the app flow: combinedOutcome folds a cancel
            // into a report whose failures carry the notification.
            return nil
        case .report(let counts):
            if counts.fail > 0 {
                // With several volumes in play a bare "failed" would hide the
                // partial result - summarise both halves.
                guard counts.ok + counts.fail + counts.skip > 1 else { return "Mount failed" }
                return "Mount failed (\(counts.ok) mounted, \(counts.fail) failed)"
            }
            if counts.ok > 0 {
                let noun = counts.ok == 1 ? "volume" : "volumes"
                return "Mounted \(counts.ok) \(noun)."
            }
            return "Nothing mounted - volumes were skipped (already mounted or being checked)."
        case .error:
            return "Mount failed"
        }
    }
}

// ---------------------------------------------------------------------------
// Ghost wording
// ---------------------------------------------------------------------------

/// What an alert says, decided here so the wording is testable.
public struct AlertText: Equatable, Sendable {
    public let message: String
    public let informative: String
    /// First is the default button.
    public let buttons: [String]
}

extension StatusMenuModel {
    public static let mountAnywayButton = "Mount Anyway"
    public static let cancelButton = "Cancel"

    /// The preventive menu item shown while a ghost is blocking.
    public static func ghostMenuTitle(_ ghost: Ghost) -> String {
        "\"\(ghost.ownerName)\" is blocking the next \"\(ghost.blockedLabel)\" card - Remount \"\(ghost.ownerName)\""
    }

    /// Offered before mounting cards a renamed card's ghost refuses. The user
    /// always chooses: remount (buttons[0]), Mount Anyway, or Cancel.
    public static func ghostStallAlert(_ ghost: Ghost, label: String, cardCount: Int) -> AlertText {
        let owner = "\"\(ghost.ownerName)\""
        let cards = cardCount == 1 ? "the new \"\(label)\" card" : "\(cardCount) new \"\(label)\" cards"
        return AlertText(
            message: "\(owner) was renamed while mounted",
            informative:
                "macOS is still holding \(ghost.record.mountedOn) for it and refuses \(cards). "
                + "Remount \(owner) to fix it? (\(owner) is unavailable for a moment; any Finder window "
                + "showing it will close.)\n\n"
                + "Mount Anyway mounts at a different path and may ask for your password; the next "
                + "\"\(label)\" card will stall again.",
            buttons: [
                cardCount == 1
                    ? "Remount \(owner) and Mount \"\(label)\"" : "Remount \(owner) and Mount \(cardCount) Cards",
                mountAnywayButton,
                cancelButton,
            ])
    }

    /// A ghost nothing mounted owns: remounting cannot help.
    public static func leakAlert(_ ghost: Ghost, label: String) -> AlertText {
        AlertText(
            message: "macOS lost track of a previous card",
            informative:
                "It still reserves \(ghost.record.mountedOn), so the \"\(label)\" card is refused. "
                + "Restart the Mac to clear it, or Mount Anyway (mounts at a different path and may ask "
                + "for your password).",
            buttons: [mountAnywayButton, cancelButton])
    }

    /// The remount was refused or failed before anything changed.
    /// `offerMountAnyway` is true at stall time, where mounting is the goal.
    public static func ghostRemountRefusedAlert(
        _ ghost: Ghost, outcome: GhostRemounter.Outcome, offerMountAnyway: Bool
    ) -> AlertText? {
        let owner = "\"\(ghost.ownerName)\""
        let tail = offerMountAnyway ? " - or Mount Anyway." : "."
        let buttons = offerMountAnyway ? [mountAnywayButton, cancelButton] : ["OK"]
        switch outcome {
        case .ownerBusy(let app):
            return AlertText(
                message: "\(owner) is in use by \(app)",
                informative: "Finish or pause the offload, then try again\(tail)",
                buttons: buttons)
        case .ownerUnmountFailed(let reason):
            return AlertText(
                message: "Could not unmount \(owner)",
                informative: "\(reason)\n\nTry again in a moment\(tail)",
                buttons: buttons)
        case .ownerNotRemounted:
            return AlertText(
                message: "\(owner) was unmounted but could not be remounted",
                informative: "Mount it from Disk Utility.",
                buttons: ["OK"])
        case .remounted:
            return nil
        }
    }

    /// Notification for a remount that went through, or nil when there is
    /// nothing to announce.
    public static func ghostRemountNotificationBody(
        _ ghost: Ghost, outcome: GhostRemounter.Outcome, announceBareRemount: Bool
    ) -> String? {
        guard case .remounted(_, let mounted, let failed, _) = outcome else { return nil }
        let owner = "Remounted \"\(ghost.ownerName)\""
        if !failed.isEmpty {
            let noun = failed.count == 1 ? "card" : "cards"
            return "\(owner), but \(failed.count) \(noun) still did not mount."
        }
        if !mounted.isEmpty {
            let noun = mounted.count == 1 ? "card" : "cards"
            return "\(owner) and mounted \(mounted.count) \(noun)."
        }
        return announceBareRemount ? "\(owner)." : nil
    }

    /// One line for the diagnostic report's event log.
    public static func ghostRemountEventLine(_ ghost: Ghost, outcome: GhostRemounter.Outcome) -> String {
        let subject =
            "remount of \"\(ghost.ownerName)\" (\(ghost.ownerDevice ?? "no owner")) for \(ghost.record.mountedOn)"
        switch outcome {
        case .remounted(let mountPoint, let mounted, let failed, let cleared):
            return "\(subject): back at \(mountPoint), \(mounted.count) stalled mounted, \(failed.count) failed, "
                + "ghost \(cleared ? "cleared" : "STILL PRESENT")"
        case .ownerBusy(let app):
            return "\(subject): refused, in use by \(app)"
        case .ownerUnmountFailed(let reason):
            return "\(subject): unmount failed: \(reason)"
        case .ownerNotRemounted:
            return "\(subject): CRITICAL - owner unmounted but not remounted"
        }
    }
}
