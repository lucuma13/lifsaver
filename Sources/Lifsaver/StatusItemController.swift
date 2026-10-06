import AppKit
import LifsaverKit
import ServiceManagement
import os

/// Everything the scanner and mounter say, kept live so diagnostic reports
/// carry what happened during past scans and mount attempts.
private let liveLog = ConsoleLog()

/// Core diagnostics also stream to the unified log, where `log stream
/// --predicate 'subsystem == "app.lifsaver"'` and Console.app can follow them
/// live. `out` is informational; `err` carries the scanner/mounter's failure
/// stream, so it logs at error level.
private let logger = Logger(subsystem: "app.lifsaver", category: "core")
private let quietConsole = liveLog.console(
    alsoTo: Console(
        out: { logger.info("\($0, privacy: .public)") },
        err: { logger.error("\($0, privacy: .public)") }
    ))

/// diskarbitrationd can keep fsck running for a while on a dirty card; while
/// it does, the card may still mount on its own. Re-check on this cadence
/// instead of calling the card stalled.
private let fsckRetryDelay: TimeInterval = 15

/// Single source for what the app says about its own distribution. The
/// packaging scripts and workflows must produce a matching asset name; releases
/// are tagged `v<version>` (enforced by publish.yml).
private let githubRepo = "lucuma13/lifsaver"
private let installerAssetName = "lifsaver_installer_macos.pkg"

/// `UpdateChecker.start()` is cache-gated to at most one request per day;
/// re-arming it on this cadence keeps a launch-at-login instance that runs for
/// weeks discovering releases, instead of only ever checking at launch.
private let updateRecheckInterval: TimeInterval = 6 * 60 * 60

/// User preferences for auto updates, start at login, and remounting renamed cards.
private let automaticUpdatesDefaultsKey = "AutomaticUpdatesEnabled"
private let remountAfterRenameDefaultsKey = "RemountAfterRenameEnabled"
private let loginItemDefaultAppliedKey = "DidApplyLoginItemDefault"

/// Owns the status-bar item and its menu. A DiskArbitration watcher rescans
/// (read-only) whenever disks appear, disappear, mount, or unmount, so
/// stalled cards are flagged proactively: the icon turns orange and a
/// clickable notification is posted. Opening the menu shows the latest
/// results immediately and reconciles with a fresh scan. What the menu says
/// is decided by `StatusMenuModel`; this class only renders it.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let scanner = DiskScanner(runner: DefaultProcessRunner(), console: quietConsole)
    private let updateChecker = UpdateChecker(
        package: "lifsaver",
        repo: githubRepo,
        currentVersion: lifsaverVersion
    )
    private var updateRecheckTimer: Timer?

    /// Monotonic token invalidating in-flight scans when a newer one starts.
    private var scanGeneration = 0
    private var mountInProgress = false

    private var lastScan: StatusMenuModel.ScanState?
    private var stalledWatch = StalledWatchState()
    private var diskWatcher: DiskActivityWatcher?
    /// Re-entrancy guard for the manual check: the menu closes on click, so a
    /// user could reopen it and click again while a fetch is still in flight.
    private var checkingForUpdates = false
    /// The "Checking for Updates…" spinner, shown only if a manual check
    /// outlasts its grace period. nil when no check is slow enough to warrant it.
    private var updateProgress: UpdateProgressWindow?
    private var menuIsOpen = false
    /// SMAppService.status is a blocking launchd XPC round-trip; query it when
    /// the menu opens or the toggle flips, not on every rebuild.
    private var launchAtLoginEnabled = false

    /// Recent scan/mount outcomes, embedded in diagnostic reports.
    private var recentEvents: [String] = []

    private var blockingGhosts: [Ghost] = []
    private var seenGhosts: Set<String> = []
    private var autoRemountTried: Set<String> = []

    private let baseIcon: NSImage?
    private let ghostIcon: NSImage?
    private let stalledIcon: NSImage?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        // Prefer the bundled lifsaver lifebuoy; fall back to the closest SF
        // Symbol when running unbundled (e.g. `swift run` during development).
        let base =
            NSImage(named: "MenuBarIcon")
            ?? NSImage(
                systemSymbolName: "lifepreserver",
                accessibilityDescription: "lifsaver"
            )
        base?.isTemplate = true
        baseIcon = base
        ghostIcon = base.map { Self.dotVariant(of: $0) }
        // The alert artwork is pre-rendered (see scripts/render/icons.sh) because turning
        // it 45° here would resample an 18px bitmap and soften it. Deliberately
        // not a template image - the orange is the signal, so the system must
        // not tint it away. Unbundled runs have no PNG to load and fall back to
        // an orange-tinted dot variant, so it stays distinct from the ghost dot.
        if let alert = NSImage(named: "MenuBarIconAlert") {
            alert.isTemplate = false
            stalledIcon = alert
        } else {
            stalledIcon = base.map { Self.dotVariant(of: $0, tint: .systemOrange) }
        }

        super.init()

        menu.delegate = self
        statusItem.menu = menu
        refreshIcon()

        // Auto updates and start-at-login are both opt-out.
        UserDefaults.standard.register(defaults: [
            automaticUpdatesDefaultsKey: true,
            remountAfterRenameDefaultsKey: false,
        ])
        applyDefaultLoginItemIfNeeded()

        Notifier.installClickHandler { [weak self] in self?.startMount() }
        // Registration replays all present disks, which triggers the first scan.
        diskWatcher = DiskActivityWatcher { [weak self] in self?.startScan() }

        if automaticUpdatesEnabled {
            updateChecker.start()
        }
        let checker = updateChecker
        let timer = Timer(timeInterval: updateRecheckInterval, repeats: true) { _ in
            guard UserDefaults.standard.bool(forKey: automaticUpdatesDefaultsKey) else { return }
            checker.start()
        }
        timer.tolerance = updateRecheckInterval / 4
        RunLoop.main.add(timer, forMode: .common)
        updateRecheckTimer = timer
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        guard !mountInProgress else { return }
        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
        // The watcher keeps `lastScan` current, so show it straight away and
        // let the reconciling scan mutate the menu in place if anything moved.
        rebuildMenu()
        startScan()
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
    }

    // MARK: - Scanning

    private func startScan() {
        scanGeneration += 1
        let generation = scanGeneration

        // The scan is async (subprocess waits suspend rather than block), so
        // it can run as a main-actor task without freezing the menu.
        let scanner = self.scanner
        Task { [weak self] in
            do {
                let devices = try await scanner.scanTargets()
                // The per-device queries are independent - fan them out instead
                // of paying one subprocess round-trip after another.
                let fsTypes = await withTaskGroup(of: (Int, String).self) { group in
                    for (index, device) in devices.enumerated() {
                        group.addTask { (index, await scanner.partitionFSType(device)) }
                    }
                    var results = [String](repeating: "", count: devices.count)
                    for await (index, fsType) in group {
                        results[index] = fsType
                    }
                    return results
                }
                let targets = zip(devices, fsTypes).map { StatusMenuModel.ScanTarget(devId: $0, fsType: $1) }
                // A card diskarbitrationd is still fsck-ing may yet mount on
                // its own - don't call it stalled. One pgrep snapshot serves
                // every device; per-device freshness only matters at mount
                // time, where Mounter re-checks.
                let fsckListing = await scanner.fsckListing()
                let settled = devices.filter { !scanner.isFsckActive($0, listing: fsckListing) }
                // Evaluated on every scan, stalled cards or not: a rename is a
                // path change, so the dot appears right after it and clears
                // once the owner is ejected or a lower path frees up.
                let ghosts = await scanner.ghosts()
                self?.finishScan(
                    .results(targets),
                    settled: settled,
                    fsckPending: settled.count != devices.count,
                    ghosts: ghosts,
                    generation: generation
                )
            } catch {
                NSLog("lifsaver scan failed: %@", "\(error)")
                self?.logEvent("scan failed: \(error)")
                self?.finishScan(.failed, settled: [], fsckPending: false, ghosts: nil, generation: generation)
            }
        }
    }

    private func finishScan(
        _ state: StatusMenuModel.ScanState,
        settled: [String],
        fsckPending: Bool,
        ghosts: [Ghost]?,
        generation: Int
    ) {
        guard generation == scanGeneration else { return }
        lastScan = state

        // A failed scan proves nothing about the disks; leave the stalled
        // state (and badge) as they were.
        if case .results = state {
            let newlyStalled = stalledWatch.update(stalled: settled)
            if let body = StatusMenuModel.stalledNotificationBody(newCount: newlyStalled.count) {
                Notifier.post(title: "lifsaver", body: body, category: Notifier.stalledVolumeCategory)
            }
            if let ghosts {
                updateGhosts(ghosts)
            }
            refreshIcon()
        }
        // Every open rebuilds anyway; while the menu is closed only the icon
        // needs to stay current.
        if menuIsOpen {
            rebuildMenu()
        }

        // fsck can finish without producing a disk event; look again shortly.
        if fsckPending {
            diskWatcher?.poke(after: fsckRetryDelay)
        }
    }

    // MARK: - Icon

    private func refreshIcon() {
        guard let button = statusItem.button else { return }
        let state = MenuBarIconState.current(
            hasStalled: stalledWatch.hasStalled, hasBlockingGhost: !blockingGhosts.isEmpty)
        switch state {
        case .stalled:
            button.image = stalledIcon ?? baseIcon
            button.toolTip = "lifsaver - stalled volume detected"
        case .ghost:
            button.image = ghostIcon ?? baseIcon
            button.toolTip = blockingGhosts.first.map {
                "lifsaver - \"\($0.ownerName)\" is blocking the next \"\($0.blockedLabel)\" card"
            }
        case .normal:
            button.image = baseIcon
            button.toolTip = "lifsaver - mount stalled camera cards"
        }
    }

    /// The menu bar icon with a dot in the lower-right corner, punched out of
    /// the artwork so the dot stays legible at menu bar size. Without a tint
    /// it stays a template image (the system supplies the colour): the ghost
    /// icon. Tinted, it stands in for the stalled artwork on unbundled runs.
    private static func dotVariant(of base: NSImage, tint: NSColor? = nil) -> NSImage {
        let image = NSImage(size: base.size, flipped: false) { rect in
            base.draw(in: rect)
            if let tint {
                tint.setFill()
                rect.fill(using: .sourceAtop)
            }
            let dotSide = rect.width * 0.4
            let dot = NSRect(x: rect.maxX - dotSide, y: 0, width: dotSide, height: dotSide)
            NSColor.black.setFill()
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            NSBezierPath(ovalIn: dot.insetBy(dx: -rect.width * 0.08, dy: -rect.width * 0.08)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            (tint ?? .black).setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        image.isTemplate = tint == nil
        return image
    }

    // MARK: - Menu construction

    private func rebuildMenu() {
        menu.removeAllItems()

        let entries = StatusMenuModel.entries(
            state: lastScan ?? .scanning,
            newerVersion: updateChecker.knownNewerVersion(),
            showLaunchAtLogin: Bundle.main.bundleIdentifier != nil,
            launchAtLoginEnabled: launchAtLoginEnabled,
            automaticUpdatesEnabled: automaticUpdatesEnabled,
            blockingGhosts: blockingGhosts,
            remountAfterRenameEnabled: remountAfterRenameEnabled
        )
        for entry in entries {
            menu.addItem(menuItem(for: entry))
        }
    }

    // MARK: - Actions

    @objc private func mountClicked() {
        startMount()
    }

    /// Shared by the menu item and notification clicks.
    private func startMount() {
        guard !mountInProgress else { return }
        mountInProgress = true

        // Stalls a ghost explains get their choice first; whatever is left
        // takes today's path. The unprivileged pass runs in-process; only if
        // it leaves something unmounted does this suspend on the password
        // dialog, whose runner does its blocking pipe reads on GCD, off the
        // main actor.
        let scanner = self.scanner
        Task { [weak self] in
            guard let self else { return }
            guard await resolveGhostStalls() == .mountRest else {
                mountInProgress = false
                diskWatcher?.poke()
                return
            }
            let outcome = await EscalatedMount.run(scanner: scanner)
            finishMount(outcome)
        }
    }

    private func finishMount(_ outcome: EscalatedMount.Outcome) {
        mountInProgress = false
        // The root pass ran in another process; its lines arrive in-band,
        // already timestamped, and slot into the live log here.
        if !outcome.helperLog.isEmpty {
            liveLog.append(["--- escalated helper (root) ---"] + outcome.helperLog)
        }
        // Logged separately from the escalated pass: whether a password was
        // needed at all is exactly what a mount bug report turns on.
        logEvent(StatusMenuModel.unprivilegedMountEventLine(for: outcome.unprivileged))
        if let escalated = outcome.escalated {
            if case .error(let message) = escalated {
                NSLog("lifsaver mount error: %@", message)
            }
            logEvent(StatusMenuModel.mountEventLine(for: escalated))
        }

        let combined = StatusMenuModel.combinedOutcome(
            unprivileged: outcome.unprivileged, escalated: outcome.escalated)
        if let body = StatusMenuModel.notificationBody(for: combined) {
            Notifier.post(title: "lifsaver", body: body)
        }
        // Successful mounts announce themselves through DiskArbitration; this
        // covers failures, so the badge and menu still tell the truth.
        diskWatcher?.poke()
    }

    @objc private func saveReportClicked() {
        DiagnosticReportFlow.begin(appEvents: recentEvents, liveLog: liveLog.snapshot())
    }

    /// Keeps the last few outcomes with timestamps; old entries roll off.
    private func logEvent(_ line: String) {
        recentEvents.append("\(ISO8601DateFormatter().string(from: Date())) \(line)")
        if recentEvents.count > 20 {
            recentEvents.removeFirst(recentEvents.count - 20)
        }
    }

    /// Manual "Check for Updates". Refetches now, bypassing the daily cache. A
    /// newer version also updates the menu item for the next time it opens.
    @objc private func checkForUpdatesClicked() {
        guard !checkingForUpdates else { return }
        checkingForUpdates = true

        // The fetch is usually sub-second but can run to the 5s timeout on a bad
        // network. Reveal a spinner only once it outstays this grace period, so
        // a fast check never flashes a window the user barely registers.
        let reveal = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            let window = UpdateProgressWindow()
            self.updateProgress = window
            window.show()
        }

        Task { [weak self] in
            guard let self else { return }
            let outcome = await updateChecker.checkNow()
            reveal.cancel()
            updateProgress?.close()
            updateProgress = nil
            checkingForUpdates = false
            rebuildMenu()
            presentManualCheckOutcome(outcome)
        }
    }

    /// Alert acknowledging a user-initiated update check. Confirm when up to
    /// date, offer the download when a newer version exists, and explain a
    /// failed check plainly.
    private func presentManualCheckOutcome(_ outcome: ManualCheckOutcome) {
        // A menu bar app is never frontmost; without activating, the alert
        // opens behind whatever the user is working in.
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        switch outcome {
        case .updateAvailable(let version):
            alert.messageText = "Update available!"
            alert.informativeText =
                "lifsaver \(version) is available now (you have \(lifsaverVersion) installed)."
            alert.addButton(withTitle: "Download…")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn {
                downloadLatestInstaller()
            }
        case .upToDate:
            alert.messageText = "You're up to date."
            alert.informativeText = "lifsaver \(lifsaverVersion) is the latest version."
            alert.addButton(withTitle: "OK")
            alert.runModal()
        case .failed:
            alert.messageText = "Update error!"
            alert.informativeText =
                "Please check your internet connection and try again."
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    /// Downloads the installer for exactly the version the menu item named. Not
    /// the `releases/latest/download/…` alias: GitHub resolves that to the
    /// newest non-prerelease release, which 404s while only prereleases exist
    /// and can serve a different version than the item advertised.
    @objc private func downloadLatestInstaller() {
        guard
            let version = updateChecker.knownNewerVersion(),
            let url = URL(
                string: "https://github.com/\(githubRepo)/releases/download/\(version)/\(installerAssetName)"
            )
        else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("lifsaver: launch-at-login toggle failed: %@", "\(error)")
        }
        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
        // Update the checkmark in place; rebuilding would dismiss the submenu.
        sender.state = launchAtLoginEnabled ? .on : .off
    }

    /// Auto updates are opt-out.
    private var automaticUpdatesEnabled: Bool {
        UserDefaults.standard.bool(forKey: automaticUpdatesDefaultsKey)
    }

    @objc private func toggleAutomaticUpdates(_ sender: NSMenuItem) {
        let enabled = !automaticUpdatesEnabled
        UserDefaults.standard.set(enabled, forKey: automaticUpdatesDefaultsKey)
        // Re-enabling should look now, not wait for the next recheck tick.
        if enabled {
            updateChecker.start()
        }
        sender.state = enabled ? .on : .off
    }

    /// Start at login: enable on first launch, then leave untouched.
    private func applyDefaultLoginItemIfNeeded() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: loginItemDefaultAppliedKey) else { return }
        defaults.set(true, forKey: loginItemDefaultAppliedKey)
        do {
            if SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("lifsaver: default launch-at-login registration failed: %@", "\(error)")
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

// MARK: - Renamed cards (ghosts)

extension StatusItemController {
    /// Takes the ghosts from the latest scan: logs new ones, keeps the
    /// blocking ones for the dot and menu, and remounts owners when the user
    /// opted in.
    private func updateGhosts(_ ghosts: [Ghost]) {
        let keys = Set(ghosts.map(Self.key(for:)))
        for ghost in ghosts where !seenGhosts.contains(Self.key(for: ghost)) {
            let blocking = scanner.isBlocking(ghost) ? "blocking" : "not blocking yet"
            if let owner = ghost.ownerDevice {
                logEvent(
                    "ghost: fskitd holds \(ghost.record.mountedOn) for \"\(ghost.ownerName)\" (\(owner), "
                        + "now at \(ghost.ownerMountPoint ?? "?")) - renamed while mounted; \(blocking)")
            } else {
                // No mounted volume owns it - not the known rename trigger.
                // Remounting cannot help; only a restart clears it.
                let line =
                    "LEAK: fskitd holds \(ghost.record.mountedOn) for \"\(ghost.record.displayName)\" "
                    + "(\(ghost.record.volumeUUID)) but no mounted volume owns it; \(blocking)"
                logEvent(line)
                quietConsole.err(line)
            }
        }
        seenGhosts = keys
        autoRemountTried.formIntersection(keys)
        blockingGhosts = ghosts.filter(scanner.isBlocking)

        guard remountAfterRenameEnabled, !mountInProgress else { return }
        if let ghost = ghosts.first(where: { !$0.isLeak && !autoRemountTried.contains(Self.key(for: $0)) }) {
            autoRemountTried.insert(Self.key(for: ghost))
            logEvent("remounting \"\(ghost.ownerName)\" automatically to release \(ghost.record.mountedOn)")
            runRemount(ghost, interactive: false)
        }
    }

    private static func key(for ghost: Ghost) -> String {
        "\(ghost.record.mountedOn)|\(ghost.record.volumeUUID)"
    }

    private enum GhostStallResolution {
        /// Run the usual mount flow for whatever is still stalled.
        case mountRest
        /// Every stalled card was dealt with here.
        case handled
        case cancelled
    }

    /// Stalled cards refused on the same ghost path, handled as one.
    private struct GhostStallGroup {
        let ghost: Ghost
        let label: String
        var devIds: [String]
    }

    /// For stalled cards a ghost explains, ask before mounting: remount the
    /// renamed owner (which clears the ghost), Mount Anyway (the raw fallback,
    /// which leaves it), or Cancel. Stalls with another cause pass through.
    private func resolveGhostStalls() async -> GhostStallResolution {
        guard let targets = try? await scanner.scanTargets() else { return .mountRest }
        var groups: [GhostStallGroup] = []
        for devId in targets {
            guard let explanation = await scanner.explainStall(devId) else { continue }
            if let index = groups.firstIndex(where: { $0.ghost.record == explanation.ghost.record }) {
                groups[index].devIds.append(devId)
            } else {
                groups.append(GhostStallGroup(ghost: explanation.ghost, label: explanation.label, devIds: [devId]))
            }
        }
        guard !groups.isEmpty else { return .mountRest }

        var remounted: Set<String> = []
        for group in groups {
            guard let mounted = await resolve(group) else { return .cancelled }
            remounted.formUnion(mounted)
        }
        return Set(targets).isSubset(of: remounted) ? .handled : .mountRest
    }

    /// One ghost's stalled cards. Returns the cards a remount mounted (empty
    /// when they are left to the usual flow), or nil when the user stopped.
    private func resolve(_ group: GhostStallGroup) async -> [String]? {
        let ghost = group.ghost
        let cards = group.devIds.joined(separator: ", ")
        if ghost.isLeak {
            logEvent("LEAK: stall of \(cards) - \(ghost.record.mountedOn) held with no mounted owner")
            guard presentAlert(StatusMenuModel.leakAlert(ghost, label: group.label), style: .warning) == 0 else {
                logEvent("mount cancelled at the leak alert")
                return nil
            }
            logEvent("user chose Mount Anyway for \(cards)")
            return []
        }

        logEvent("stall of \(cards) explained: \(ghost.record.mountedOn) held by \"\(ghost.ownerName)\"")
        let offer = StatusMenuModel.ghostStallAlert(ghost, label: group.label, cardCount: group.devIds.count)
        switch presentAlert(offer) {
        case 0:
            break
        case 1:
            logEvent("user chose Mount Anyway for \(cards)")
            return []
        default:
            logEvent("mount cancelled at the remount offer")
            return nil
        }

        logEvent("user chose to remount \"\(ghost.ownerName)\"")
        let outcome = await GhostRemounter(scanner: scanner).remount(ghost, stalled: group.devIds)
        logEvent(StatusMenuModel.ghostRemountEventLine(ghost, outcome: outcome))
        if case .remounted(_, let mounted, _, _) = outcome {
            let body = StatusMenuModel.ghostRemountNotificationBody(ghost, outcome: outcome, announceBareRemount: true)
            body.map { Notifier.post(title: "lifsaver", body: $0) }
            return mounted
        }
        // Refused or failed: Mount Anyway stays on offer, except for an owner
        // left unmounted, which stops everything.
        let critical = outcome == .ownerNotRemounted
        let refusal = StatusMenuModel.ghostRemountRefusedAlert(ghost, outcome: outcome, offerMountAnyway: true)
        guard let refusal, presentAlert(refusal, style: critical ? .critical : .warning) == 0, !critical else {
            logEvent("mount stopped after the remount of \"\(ghost.ownerName)\" failed")
            return nil
        }
        logEvent("user chose Mount Anyway for \(cards)")
        return []
    }

    @objc private func remountGhostClicked(_ sender: NSMenuItem) {
        guard
            let owner = sender.representedObject as? String,
            let ghost = blockingGhosts.first(where: { $0.ownerDevice == owner })
        else { return }
        logEvent("user chose to remount \"\(ghost.ownerName)\" from the menu")
        runRemount(ghost, interactive: true)
    }

    /// Remount a ghost's owner outside the mount flow (menu item or the
    /// automatic setting), taking along any card already stalled behind it.
    private func runRemount(_ ghost: Ghost, interactive: Bool) {
        guard !mountInProgress else { return }
        mountInProgress = true
        let scanner = self.scanner
        Task { [weak self] in
            var stalled: [String] = []
            for devId in (try? await scanner.scanTargets()) ?? [] {
                guard await scanner.ghostRecord(blocking: devId)?.record == ghost.record else { continue }
                stalled.append(devId)
            }
            let outcome = await GhostRemounter(scanner: scanner).remount(ghost, stalled: stalled)
            self?.finishRemount(ghost, outcome: outcome, interactive: interactive)
        }
    }

    private func finishRemount(_ ghost: Ghost, outcome: GhostRemounter.Outcome, interactive: Bool) {
        mountInProgress = false
        logEvent(StatusMenuModel.ghostRemountEventLine(ghost, outcome: outcome))
        let body = StatusMenuModel.ghostRemountNotificationBody(
            ghost, outcome: outcome, announceBareRemount: interactive)
        body.map { Notifier.post(title: "lifsaver", body: $0) }
        // An automatic remount refused or failed falls back to the dot and the
        // menu item - except an owner left unmounted, which is never silent.
        let critical = outcome == .ownerNotRemounted
        let refusal = StatusMenuModel.ghostRemountRefusedAlert(ghost, outcome: outcome, offerMountAnyway: false)
        if let refusal, interactive || critical {
            presentAlert(refusal, style: critical ? .critical : .warning)
        }
        diskWatcher?.poke()
    }

    /// Runs a modal alert and returns the index of the button chosen.
    @discardableResult
    private func presentAlert(_ text: AlertText, style: NSAlert.Style = .informational) -> Int {
        // A menu bar app is never frontmost; without activating, the alert
        // opens behind whatever the user is working in.
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = text.message
        alert.informativeText = text.informative
        for button in text.buttons {
            alert.addButton(withTitle: button)
        }
        return alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    }

    /// Off by default: remounting takes a card offline for a moment, which an
    /// offload app may not expect.
    private var remountAfterRenameEnabled: Bool {
        UserDefaults.standard.bool(forKey: remountAfterRenameDefaultsKey)
    }

    @objc private func toggleRemountAfterRename(_ sender: NSMenuItem) {
        let enabled = !remountAfterRenameEnabled
        UserDefaults.standard.set(enabled, forKey: remountAfterRenameDefaultsKey)
        logEvent("remount cards automatically after renaming: \(enabled ? "on" : "off")")
        // Turning it on should act on a ghost that is already there.
        if enabled {
            autoRemountTried.removeAll()
            diskWatcher?.poke()
        }
        sender.state = enabled ? .on : .off
    }
}

// MARK: - Menu entry rendering

extension StatusItemController {
    fileprivate func menuItem(for entry: StatusMenuModel.Entry) -> NSMenuItem {
        switch entry {
        case .separator:
            return NSMenuItem.separator()
        case .disabled(let title):
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            return item
        case .mount(let title):
            return actionItem(title: title, action: #selector(mountClicked))
        case .remountGhost(let title, let ownerDevice):
            let item = actionItem(title: title, action: #selector(remountGhostClicked))
            item.representedObject = ownerDevice
            return item
        case .checkForUpdates(let title):
            return actionItem(title: title, action: #selector(checkForUpdatesClicked))
        case .updateAvailable(let title):
            return actionItem(title: title, action: #selector(downloadLatestInstaller))
        case .moreOptions(
            let showStartAtLogin, let startAtLoginEnabled, let automaticUpdatesEnabled, let remountAfterRenameEnabled):
            let item = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            if showStartAtLogin {
                let login = actionItem(title: "Start at Login", action: #selector(toggleLaunchAtLogin))
                login.state = startAtLoginEnabled ? .on : .off
                submenu.addItem(login)
            }
            let auto = actionItem(
                title: "Automatically Check for Updates", action: #selector(toggleAutomaticUpdates))
            auto.state = automaticUpdatesEnabled ? .on : .off
            submenu.addItem(auto)
            let remount = actionItem(
                title: "Remount Cards Automatically After Renaming", action: #selector(toggleRemountAfterRename))
            remount.state = remountAfterRenameEnabled ? .on : .off
            submenu.addItem(remount)
            item.submenu = submenu
            return item
        case .saveReport(let title):
            return actionItem(title: title, action: #selector(saveReportClicked))
        case .quit(let title):
            return actionItem(title: title, action: #selector(quit), keyEquivalent: "q")
        }
    }

    private func actionItem(title: String, action: Selector, keyEquivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }
}

/// "Checking for Updates…" window shown while a slow manual check is in flight,
/// dismissed the moment it returns.
@MainActor
final class UpdateProgressWindow {
    private let window: NSWindow

    init() {
        let padding: CGFloat = 20
        let iconSide: CGFloat = 64
        let gap: CGFloat = 16
        let textWidth: CGFloat = 240
        let width = padding + iconSide + gap + textWidth + padding
        let height = padding + iconSide + padding
        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))

        // The same app icon NSAlert draws, so the progress and result screens
        // share their branding.
        let icon = NSImageView(
            frame: NSRect(x: padding, y: height - padding - iconSide, width: iconSide, height: iconSide))
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        content.addSubview(icon)

        let textX = padding + iconSide + gap
        let title = NSTextField(labelWithString: "Checking for Updates…")
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        title.frame = NSRect(x: textX, y: height - padding - 20, width: textWidth, height: 20)
        content.addSubview(title)

        let bar = NSProgressIndicator(
            frame: NSRect(x: textX, y: height - padding - 52, width: textWidth, height: 20))
        bar.style = .bar
        bar.isIndeterminate = true
        bar.startAnimation(nil)
        content.addSubview(bar)

        // No .closable/.miniaturizable: the window has no manual dismissal -
        // it lives exactly as long as the fetch.
        window = NSWindow(
            contentRect: content.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "lifsaver"
        window.contentView = content
        window.isReleasedWhenClosed = false
        window.center()
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window.orderOut(nil)
    }
}
