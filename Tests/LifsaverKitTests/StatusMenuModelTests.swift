import Testing

@testable import LifsaverKit

// ===========================================================================
// Menu entries
// ===========================================================================

@Suite struct StatusMenuEntriesTests {
    /// Entries shared by every state, with defaults for the knobs under test.
    private func entries(
        state: StatusMenuModel.ScanState,
        newerVersion: String? = nil,
        isCheckingForUpdates: Bool = false,
        showLaunchAtLogin: Bool = false,
        launchAtLoginEnabled: Bool = false,
        automaticUpdatesEnabled: Bool = true
    ) -> [StatusMenuModel.Entry] {
        StatusMenuModel.entries(
            state: state,
            newerVersion: newerVersion,
            isCheckingForUpdates: isCheckingForUpdates,
            showLaunchAtLogin: showLaunchAtLogin,
            launchAtLoginEnabled: launchAtLoginEnabled,
            automaticUpdatesEnabled: automaticUpdatesEnabled
        )
    }

    /// The "Settings" submenu with the test defaults (unbundled, auto-check on).
    private let moreOptions = StatusMenuModel.Entry.moreOptions(
        showStartAtLogin: false, startAtLoginEnabled: false, automaticUpdatesEnabled: true)

    @Test func scanningShowsPlaceholder() {
        #expect(
            entries(state: .scanning) == [
                .disabled("Scanning…"),
                .separator,
                .saveReport(title: "Send Diagnostic Report"),
                .checkForUpdates(title: "Check for Updates"),
                moreOptions,
                .quit(title: "Quit"),
            ])
    }

    @Test func failureShowsDisabledNotice() {
        #expect(
            entries(state: .failed) == [
                .disabled("Scan failed"),
                .separator,
                .saveReport(title: "Send Diagnostic Report"),
                .checkForUpdates(title: "Check for Updates"),
                moreOptions,
                .quit(title: "Quit"),
            ])
    }

    @Test func noTargetsShowsAllClear() {
        #expect(
            entries(state: .results([])) == [
                .disabled("No stalled volumes detected"),
                .separator,
                .saveReport(title: "Send Diagnostic Report"),
                .checkForUpdates(title: "Check for Updates"),
                moreOptions,
                .quit(title: "Quit"),
            ])
    }

    @Test func singleTargetUsesSingularNoun() {
        let target = StatusMenuModel.ScanTarget(devId: "disk4s1", fsType: "msdos")
        #expect(
            entries(state: .results([target])) == [
                .mount(title: "Mount 1 stalled volume"),
                .separator,
                .saveReport(title: "Send Diagnostic Report"),
                .checkForUpdates(title: "Check for Updates"),
                moreOptions,
                .quit(title: "Quit"),
            ])
    }

    @Test func multipleTargetsUsePluralNoun() {
        let targets = [
            StatusMenuModel.ScanTarget(devId: "disk4s1", fsType: "msdos"),
            StatusMenuModel.ScanTarget(devId: "disk5s1", fsType: ""),
        ]
        #expect(
            entries(state: .results(targets)) == [
                .mount(title: "Mount 2 stalled volumes"),
                .separator,
                .saveReport(title: "Send Diagnostic Report"),
                .checkForUpdates(title: "Check for Updates"),
                moreOptions,
                .quit(title: "Quit"),
            ])
    }

    @Test func newerVersionReplacesCheckItemWithUpdate() {
        let result = entries(state: .scanning, newerVersion: "2.1.0")
        #expect(result.contains(.updateAvailable(title: "Update to version 2.1.0")))
        #expect(!result.contains(.checkForUpdates(title: "Check for Updates")))
        #expect(result.last == .quit(title: "Quit"))
    }

    @Test func checkingShowsProgressPlaceholder() {
        let result = entries(state: .scanning, isCheckingForUpdates: true)
        #expect(result.contains(.disabled("Checking for Updates…")))
        #expect(!result.contains(.checkForUpdates(title: "Check for Updates")))
    }

    @Test func knownUpdateWinsOverCheckingState() {
        // A newer version already in hand shows the update item, not progress.
        let result = entries(state: .scanning, newerVersion: "2.1.0", isCheckingForUpdates: true)
        #expect(result.contains(.updateAvailable(title: "Update to version 2.1.0")))
        #expect(!result.contains(.disabled("Checking for Updates…")))
    }

    @Test func moreOptionsHidesStartAtLoginWhenUnbundled() {
        #expect(
            entries(state: .scanning).contains(
                .moreOptions(showStartAtLogin: false, startAtLoginEnabled: false, automaticUpdatesEnabled: true)))

        let bundled = entries(state: .scanning, showLaunchAtLogin: true, launchAtLoginEnabled: true)
        #expect(
            bundled.contains(
                .moreOptions(showStartAtLogin: true, startAtLoginEnabled: true, automaticUpdatesEnabled: true)))
    }

    @Test func moreOptionsReflectsAutomaticUpdatesOptOut() {
        let optedOut = entries(state: .scanning, automaticUpdatesEnabled: false)
        #expect(
            optedOut.contains(
                .moreOptions(showStartAtLogin: false, startAtLoginEnabled: false, automaticUpdatesEnabled: false)))
    }

    /// Reports are most needed exactly when scans fail, so the item must
    /// survive every scan state.
    @Test func saveReportPresentInEveryState() {
        let states: [StatusMenuModel.ScanState] = [.scanning, .failed, .results([])]
        for state in states {
            #expect(entries(state: state).contains(.saveReport(title: "Send Diagnostic Report")))
        }
    }
}

// ===========================================================================
// Report event lines
// ===========================================================================

@Suite struct MountEventLineTests {
    @Test func cancellationIsRecordedUnlikeTheNotification() {
        #expect(
            StatusMenuModel.mountEventLine(for: .cancelled)
                == "mount attempt cancelled at the password dialog")
    }

    @Test func errorKeepsRawMessage() {
        #expect(
            StatusMenuModel.mountEventLine(for: .error("osascript exploded"))
                == "mount attempt failed: osascript exploded")
    }

    @Test func reportSummarizesCounts() {
        #expect(
            StatusMenuModel.mountEventLine(for: .report(.init(ok: 1, fail: 2, skip: 3)))
                == "mount attempt finished: 1 mounted, 2 failed, 3 skipped")
    }

    @Test func unprivilegedPassRecordsWhatRootWasNeededFor() {
        #expect(
            StatusMenuModel.unprivilegedMountEventLine(for: .init(ok: 1, fail: 2, skip: 3))
                == "unprivileged mount pass: 1 mounted, 2 need elevation, 3 skipped")
    }
}

// ===========================================================================
// Combining the two mount passes
// ===========================================================================

@Suite struct CombinedOutcomeTests {
    private func combined(
        _ unprivileged: MountReport.Counts, _ escalated: EscalatedMountOutcome?
    ) -> EscalatedMountOutcome {
        StatusMenuModel.combinedOutcome(unprivileged: unprivileged, escalated: escalated)
    }

    @Test func noEscalationReportsTheFirstPassAlone() {
        // The whole point of the change: everything mounted, no password asked.
        #expect(combined(.init(ok: 2), nil) == .report(.init(ok: 2)))
    }

    @Test func successesFromBothPassesAreAddedUp() {
        // One volume mounted unprivileged, a second needed root: the user
        // mounted two volumes and should be told so.
        #expect(
            combined(.init(ok: 1, fail: 1), .report(.init(ok: 1)))
                == .report(.init(ok: 2, fail: 0, skip: 0)))
    }

    @Test func escalatedCountsOwnFailuresAndSkips() {
        // The first pass's fail/skip were rescanned under root, so counting
        // them again here would double-report the same volume.
        #expect(
            combined(.init(ok: 1, fail: 2, skip: 1), .report(.init(ok: 1, fail: 1, skip: 1)))
                == .report(.init(ok: 2, fail: 1, skip: 1)))
    }

    @Test func cancellationAloneReportsTheDeclinedVolumesAsFailed() {
        // Declining the password leaves the volume unmounted — a failure.
        #expect(combined(.init(fail: 1), .cancelled) == .report(.init(fail: 1)))
    }

    @Test func cancellingTheRestFailsThemAndKeepsWhatAlreadyMounted() {
        // What mounted before the prompt still counts; what the user declined
        // to authorize is reported as failed, not silently dropped.
        #expect(combined(.init(ok: 1, fail: 1), .cancelled) == .report(.init(ok: 1, fail: 1)))
    }

    @Test func errorAlonePassesThrough() {
        #expect(combined(.init(fail: 1), .error("osascript exploded")) == .error("osascript exploded"))
    }

    @Test func errorAfterPartialSuccessKeepsBothHalves() {
        // The escalation never ran, so the first pass's failures still stand.
        #expect(
            combined(.init(ok: 1, fail: 2), .error("osascript exploded"))
                == .report(.init(ok: 1, fail: 2)))
    }
}

// ===========================================================================
// Target detail
// ===========================================================================

@Suite struct ScanTargetDetailTests {
    @Test func includesFSTypeWhenKnown() {
        #expect(StatusMenuModel.ScanTarget(devId: "disk4s1", fsType: "exfat").detail == "disk4s1 — exfat")
    }

    @Test func fallsBackToDeviceWhenFSTypeUnknown() {
        #expect(StatusMenuModel.ScanTarget(devId: "disk4s1", fsType: "").detail == "disk4s1")
    }
}

// ===========================================================================
// Mount notifications
// ===========================================================================

@Suite struct MountNotificationTests {
    private func body(for outcome: EscalatedMountOutcome) -> String? {
        StatusMenuModel.notificationBody(for: outcome)
    }

    @Test func cancelledIsSilent() {
        #expect(body(for: .cancelled) == nil)
    }

    @Test func singleVolumeFailureIsPlain() {
        #expect(body(for: .report(.init(ok: 0, fail: 1, skip: 0))) == "Mount failed")
    }

    @Test func multiVolumeFailureSummarisesBothHalves() {
        #expect(
            body(for: .report(.init(ok: 2, fail: 1, skip: 0)))
                == "Mount failed (2 mounted, 1 failed)")
    }

    @Test func allVolumesFailingStillSummarisesWhenSeveral() {
        #expect(
            body(for: .report(.init(ok: 0, fail: 2, skip: 0)))
                == "Mount failed (0 mounted, 2 failed)")
    }

    @Test func singleSuccessUsesSingularNoun() {
        #expect(body(for: .report(.init(ok: 1, fail: 0, skip: 0))) == "Mounted 1 volume.")
    }

    @Test func multipleSuccessesUsePluralNoun() {
        #expect(body(for: .report(.init(ok: 3, fail: 0, skip: 0))) == "Mounted 3 volumes.")
    }

    @Test func allSkippedExplainsWhyNothingMounted() {
        #expect(
            body(for: .report(.init(ok: 0, fail: 0, skip: 2)))
                == "Nothing mounted — volumes were skipped (already mounted or being checked).")
    }

    @Test func errorReportsPlainFailure() {
        #expect(body(for: .error("osascript exploded")) == "Mount failed")
    }
}

// ===========================================================================
// Stalled-volume watching
// ===========================================================================

@Suite struct StalledWatchStateTests {
    @Test func firstSightingReportsEveryDeviceInScanOrder() {
        var state = StalledWatchState()
        #expect(state.update(stalled: ["disk4s1", "disk5s1"]) == ["disk4s1", "disk5s1"])
        #expect(state.hasStalled)
    }

    @Test func unchangedRescanReportsNothingNew() {
        var state = StalledWatchState()
        _ = state.update(stalled: ["disk4s1"])
        #expect(state.update(stalled: ["disk4s1"]).isEmpty)
        #expect(state.hasStalled)
    }

    @Test func onlyAdditionsAreReported() {
        var state = StalledWatchState()
        _ = state.update(stalled: ["disk4s1"])
        #expect(state.update(stalled: ["disk4s1", "disk5s1"]) == ["disk5s1"])
    }

    @Test func emptyScanClearsTheState() {
        var state = StalledWatchState()
        _ = state.update(stalled: ["disk4s1"])
        #expect(state.update(stalled: []).isEmpty)
        #expect(!state.hasStalled)
    }

    @Test func deviceThatLeftAndReturnedIsNewAgain() {
        var state = StalledWatchState()
        _ = state.update(stalled: ["disk4s1"])
        _ = state.update(stalled: [])
        #expect(state.update(stalled: ["disk4s1"]) == ["disk4s1"])
    }
}

@Suite struct StalledNotificationTests {
    @Test func zeroNewDevicesIsSilent() {
        #expect(StatusMenuModel.stalledNotificationBody(newCount: 0) == nil)
    }

    @Test func singleDeviceUsesSingularNoun() {
        #expect(
            StatusMenuModel.stalledNotificationBody(newCount: 1)
                == "Stalled volume detected")
    }

    @Test func multipleDevicesUsePluralNounAndCount() {
        #expect(
            StatusMenuModel.stalledNotificationBody(newCount: 3)
                == "3 stalled volumes detected")
    }
}
