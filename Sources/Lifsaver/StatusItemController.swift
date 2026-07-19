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

/// User preferences for auto updates and start at login.
private let automaticUpdatesDefaultsKey = "AutomaticUpdatesEnabled"
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

        // Auto updates and start-at-login are both opt-out.
        UserDefaults.standard.register(defaults: [automaticUpdatesDefaultsKey: true])
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
                // The per-device queries are independent — fan them out instead
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
                // its own — don't call it stalled. One pgrep snapshot serves
                // every device; per-device freshness only matters at mount
                // time, where Mounter re-checks.
                let fsckListing = await scanner.fsckListing()
                let settled = devices.filter { !scanner.isFsckActive($0, listing: fsckListing) }
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
        guard generation == scanGeneration else { return }
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

    private func rebuildMenu() {
        menu.removeAllItems()

        let entries = StatusMenuModel.entries(
            state: lastScan ?? .scanning,
            newerVersion: updateChecker.knownNewerVersion(),
            showLaunchAtLogin: Bundle.main.bundleIdentifier != nil,
            launchAtLoginEnabled: launchAtLoginEnabled,
            automaticUpdatesEnabled: automaticUpdatesEnabled
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

        // The unprivileged pass runs in-process; only if it leaves something
        // unmounted does this suspend on the password dialog, whose runner does
        // its blocking pipe reads on GCD, off the main actor.
        let scanner = self.scanner
        Task { [weak self] in
            let outcome = await EscalatedMount.run(scanner: scanner)
            self?.finishMount(outcome)
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
        case .checkForUpdates(let title):
            return actionItem(title: title, action: #selector(checkForUpdatesClicked))
        case .updateAvailable(let title):
            return actionItem(title: title, action: #selector(downloadLatestInstaller))
        case .moreOptions(let showStartAtLogin, let startAtLoginEnabled, let automaticUpdatesEnabled):
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

        // No .closable/.miniaturizable: the window has no manual dismissal —
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
