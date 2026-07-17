import AppKit
import LifsaverCore
import ServiceManagement

/// Diagnostics from the core land in the log, never in a terminal that
/// doesn't exist.
private let quietConsole = Console(
    out: { NSLog("lifsaver: %@", $0) },
    err: { NSLog("lifsaver: %@", $0) }
)

/// diskarbitrationd can keep fsck running for a while on a dirty card; while
/// it does, the card may still mount on its own. Re-check on this cadence
/// instead of calling the card stalled.
private let fsckRetryDelay: TimeInterval = 15

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
        repo: "lucuma13/lifsaver",
        currentVersion: lifsaverVersion,
        upgradeCommand: lifsaverUpgradeCommand(),
        // The app has no meaningful tty; the checker is used only as a data
        // source for the "Update available" menu item.
        stderrIsInteractive: { true }
    )

    /// Invalidates in-flight scans when a newer one starts.
    private var scanGeneration = ScanGeneration()
    private var mountInProgress = false

    private var lastScan: StatusMenuModel.ScanState?
    private var stalledWatch = StalledWatchState()
    private var diskWatcher: DiskActivityWatcher?
    private var checkingForUpdates = false

    /// Recent scan/mount outcomes, embedded in diagnostic reports.
    private var recentEvents: [String] = []

    private let baseIcon: NSImage?
    private let attentionIcon: NSImage?

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
        // The alert artwork is pre-rendered (see scripts/render/icons.sh) because turning
        // it 45° here would resample an 18px bitmap and soften it. Deliberately
        // not a template image — the orange is the signal, so the system must
        // not tint it away. Unbundled runs have no PNG to load and fall back to
        // punching a dot out of whatever base we ended up with.
        if let alert = NSImage(named: "MenuBarIconAlert") {
            alert.isTemplate = false
            attentionIcon = alert
        } else {
            attentionIcon = base.map(Self.attentionVariant(of:))
        }

        super.init()

        menu.delegate = self
        statusItem.menu = menu
        refreshIcon()

        Notifier.installClickHandler { [weak self] in self?.startMount() }
        // Registration replays all present disks, which triggers the first scan.
        diskWatcher = DiskActivityWatcher { [weak self] in self?.startScan() }

        updateChecker.start()
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        guard !mountInProgress else { return }
        // The watcher keeps `lastScan` current, so show it straight away and
        // let the reconciling scan mutate the menu in place if anything moved.
        rebuildMenu(state: lastScan ?? .scanning)
        startScan()
    }

    // MARK: - Scanning

    private func startScan() {
        let generation = scanGeneration.begin()

        // The scan is async (subprocess waits suspend rather than block), so
        // it can run as a main-actor task without freezing the menu.
        let scanner = self.scanner
        Task { [weak self] in
            do {
                let devices = try await scanner.scanTargets()
                var targets: [StatusMenuModel.ScanTarget] = []
                var settled: [String] = []
                for device in devices {
                    targets.append(
                        StatusMenuModel.ScanTarget(
                            devId: device,
                            fsType: await scanner.partitionFSType(device)
                        )
                    )
                    // A card diskarbitrationd is still fsck-ing may yet mount
                    // on its own — don't call it stalled.
                    if !(await scanner.isFsckActive(device)) {
                        settled.append(device)
                    }
                }
                self?.finishScan(
                    .results(targets),
                    settled: settled,
                    fsckPending: settled.count != devices.count,
                    generation: generation
                )
            } catch {
                NSLog("lifsaver scan failed: %@", "\(error)")
                self?.logEvent("scan failed: \(error)")
                self?.finishScan(.failed, settled: [], fsckPending: false, generation: generation)
            }
        }
    }

    private func finishScan(
        _ state: StatusMenuModel.ScanState,
        settled: [String],
        fsckPending: Bool,
        generation: Int
    ) {
        guard scanGeneration.isCurrent(generation) else { return }
        lastScan = state

        // A failed scan proves nothing about the disks; leave the stalled
        // state (and badge) as they were.
        if case .results = state {
            let newlyStalled = stalledWatch.update(stalled: settled)
            if let body = StatusMenuModel.stalledNotificationBody(newCount: newlyStalled.count) {
                Notifier.post(title: "lifsaver", body: body, category: Notifier.stalledVolumeCategory)
            }
            refreshIcon()
        }
        rebuildMenu(state: state)

        // fsck can finish without producing a disk event; look again shortly.
        if fsckPending {
            diskWatcher?.poke(after: fsckRetryDelay)
        }
    }

    // MARK: - Icon

    private func refreshIcon() {
        guard let button = statusItem.button else { return }
        let attention = stalledWatch.hasStalled
        button.image = (attention ? attentionIcon : baseIcon) ?? baseIcon
        button.toolTip =
            attention
            ? "lifsaver — stalled volume detected"
            : "lifsaver — mount stalled camera cards"
    }

    /// The menu bar icon with an alert dot in the lower-right corner, punched
    /// out of the artwork so the dot stays legible at menu bar size. Still a
    /// template image: the system supplies the colour.
    private static func attentionVariant(of base: NSImage) -> NSImage {
        let image = NSImage(size: base.size, flipped: false) { rect in
            base.draw(in: rect)
            let dotSide = rect.width * 0.4
            let dot = NSRect(x: rect.maxX - dotSide, y: 0, width: dotSide, height: dotSide)
            NSColor.black.setFill()
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            NSBezierPath(ovalIn: dot.insetBy(dx: -rect.width * 0.08, dy: -rect.width * 0.08)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: - Menu construction

    private func rebuildMenu(state: StatusMenuModel.ScanState) {
        menu.removeAllItems()

        let entries = StatusMenuModel.entries(
            state: state,
            newerVersion: updateChecker.knownNewerVersion(),
            isCheckingForUpdates: checkingForUpdates,
            showLaunchAtLogin: Bundle.main.bundleIdentifier != nil,
            launchAtLoginEnabled: SMAppService.mainApp.status == .enabled
        )
        for entry in entries {
            menu.addItem(menuItem(for: entry))
        }
    }

    private func menuItem(for entry: StatusMenuModel.Entry) -> NSMenuItem {
        switch entry {
        case .separator:
            return NSMenuItem.separator()
        case .disabled(let title):
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            return item
        case .mount(let title):
            return actionItem(title: title, action: #selector(mountClicked))
        case .checkForUpdates(let title):
            return actionItem(title: title, action: #selector(checkForUpdatesClicked))
        case .updateAvailable(let title):
            return actionItem(title: title, action: #selector(downloadLatestInstaller))
        case .launchAtLogin(let enabled):
            let item = actionItem(title: "Start at Login", action: #selector(toggleLaunchAtLogin))
            item.state = enabled ? .on : .off
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

    // MARK: - Actions

    @objc private func mountClicked() {
        startMount()
    }

    /// Shared by the menu item and notification clicks.
    private func startMount() {
        guard !mountInProgress else { return }
        mountInProgress = true

        // The unprivileged pass runs in-process; only if it leaves something
        // unmounted does this suspend on the password dialog, whose runner does
        // its blocking pipe reads on GCD, off the main actor.
        let scanner = self.scanner
        Task { [weak self] in
            let outcome = await MountCoordinator.run(scanner: scanner)
            self?.finishMount(outcome)
        }
    }

    private func finishMount(_ outcome: MountCoordinator.Outcome) {
        mountInProgress = false
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
        DiagnosticReportFlow.begin(appEvents: recentEvents)
    }

    /// Keeps the last few outcomes with timestamps; old entries roll off.
    private func logEvent(_ line: String) {
        recentEvents.append("\(ISO8601DateFormatter().string(from: Date())) \(line)")
        if recentEvents.count > 20 {
            recentEvents.removeFirst(recentEvents.count - 20)
        }
    }

    /// Manual "Check for Updates". Refetches now, bypassing the daily cache,
    /// and swaps the item to "Update to version …" if the check turns one up.
    @objc private func checkForUpdatesClicked() {
        guard !checkingForUpdates else { return }
        checkingForUpdates = true
        rebuildMenu(state: lastScan ?? .scanning)

        Task { [weak self] in
            guard let self else { return }
            await updateChecker.checkNow()
            checkingForUpdates = false
            rebuildMenu(state: lastScan ?? .scanning)
        }
    }

    /// Downloads the latest installer directly rather than sending the user to
    /// the releases page. The asset name is frozen and matches the CLI's hint.
    @objc private func downloadLatestInstaller() {
        let url = URL(
            string:
                "https://github.com/lucuma13/lifsaver/releases/latest/download/lifsaver_installer_macos.pkg"
        )
        if let url {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("lifsaver: launch-at-login toggle failed: %@", "\(error)")
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
