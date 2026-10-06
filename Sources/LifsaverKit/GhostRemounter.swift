import Foundation

// ---------------------------------------------------------------------------
// Ghost remount
// ---------------------------------------------------------------------------

/// Clears a ghost by remounting its owner, then mounts the cards it blocked.
///
/// Unmounting the renamed owner is what makes fskitd release the stale path;
/// mounting it again records it at its current path. Owner first, then the
/// stalled cards, so the owner is offline only for a moment. Everything is
/// unprivileged `diskutil`, and the unmount is never forced: diskutil refuses
/// while a file on the card is open, which is exactly the protection an
/// offload in progress needs.
public struct GhostRemounter: Sendable {
    public enum Outcome: Equatable, Sendable {
        /// The owner is back at `ownerMountPoint`; the stalled cards split into
        /// those now mounted and those still refused.
        case remounted(ownerMountPoint: String, mounted: [String], failed: [String], ghostCleared: Bool)
        /// diskutil would not unmount the owner because `app` has a file open on it.
        case ownerBusy(app: String)
        /// The owner could not be unmounted for another reason (or is no longer
        /// mounted at all). Nothing changed.
        case ownerUnmountFailed(String)
        /// The owner was unmounted but would not mount again - the one outcome
        /// that leaves a card offline. Never to be swallowed.
        case ownerNotRemounted
    }

    public let scanner: DiskScanner
    /// Pause before the single retry of the owner's mount.
    public let retryDelay: Duration

    public init(scanner: DiskScanner, retryDelay: Duration = .seconds(2)) {
        self.scanner = scanner
        self.retryDelay = retryDelay
    }

    var console: Console { scanner.console }

    public func remount(_ ghost: Ghost, stalled: [String] = []) async -> Outcome {
        guard let owner = ghost.ownerDevice else {
            return .ownerUnmountFailed("no mounted volume owns \(ghost.record.mountedOn)")
        }
        let name = "\"\(ghost.ownerName)\""
        console.out("Remounting \(name) (/dev/\(owner)) to release \(ghost.record.mountedOn)...")

        // 1. Unmount the owner, never forced.
        if let refusal = await unmount(owner, name: name) {
            return refusal
        }

        // 2. Mount the owner straight back, retrying once: from here on a
        // failure leaves a card offline, so it must be loud.
        var ownerBack = await mount(owner)
        if !ownerBack {
            console.err("  \(name) did not remount; retrying once...")
            try? await Task.sleep(for: retryDelay)
            ownerBack = await mount(owner)
        }
        guard ownerBack else {
            console.err(
                "  CRITICAL: \(name) (/dev/\(owner)) was unmounted but could not be remounted - "
                    + "mount it from Disk Utility.")
            return .ownerNotRemounted
        }
        let ownerMountPoint = scanner.mountPoint(of: owner)
        console.out("  \(name) remounted at \(ownerMountPoint.isEmpty ? "(see /Volumes)" : ownerMountPoint).")

        // 3. The cards the ghost blocked.
        var mounted: [String] = []
        var failed: [String] = []
        for devId in stalled {
            if await mount(devId) {
                console.out("  Mounted /dev/\(devId) at \(scanner.mountPoint(of: devId)).")
                mounted.append(devId)
            } else {
                console.err("  /dev/\(devId) still failed to mount after the remount.")
                failed.append(devId)
            }
        }

        // 4. Confirm fskitd let go of the path.
        let cleared = !scanner.ghostFSKitMounts().contains { $0.mountedOn == ghost.record.mountedOn }
        if !cleared {
            console.err("  fskitd still reserves \(ghost.record.mountedOn) after remounting \(name).")
        }
        return .remounted(ownerMountPoint: ownerMountPoint, mounted: mounted, failed: failed, ghostCleared: cleared)
    }

    /// `diskutil unmount`, never forced: nil when the owner is unmounted,
    /// otherwise why not.
    private func unmount(_ owner: String, name: String) async -> Outcome? {
        let result: ProcessResult
        do {
            result = try await scanner.runner.run("diskutil", ["unmount", owner], timeout: mountTimeout)
        } catch {
            console.err("  Could not unmount \(name): \(error)")
            return .ownerUnmountFailed("\(error)")
        }
        guard result.status != 0 else { return nil }
        let message = [result.stdoutText, result.stderr]
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if let app = Self.dissentingApp(in: message) {
            console.out("  \(name) is in use by \(app); left mounted. diskutil: \(message)")
            return .ownerBusy(app: app)
        }
        console.err("  Could not unmount \(name): \(message)")
        return .ownerUnmountFailed(message.isEmpty ? "diskutil exited \(result.status)" : message)
    }

    /// `diskutil mount`, verified against the mount table. An unreadable table
    /// lets the zero exit stand, as in `Mounter.attemptMounts`.
    private func mount(_ devId: String) async -> Bool {
        guard let result = try? await scanner.runner.run("diskutil", ["mount", devId], timeout: mountTimeout)
        else { return false }
        return result.status == 0 && scanner.isCurrentlyMounted(devId) != false
    }

    /// The app holding a volume open, from diskutil's refusal:
    /// `... failed to unmount: dissented by PID 471 (/bin/bash)`.
    static func dissentingApp(in message: String) -> String? {
        guard
            let regex = try? NSRegularExpression(pattern: #"dissented by PID (\d+)(?: \(([^)]*)\))?"#),
            let match = regex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message))
        else { return nil }
        if let pathRange = Range(match.range(at: 2), in: message), !message[pathRange].isEmpty {
            return (String(message[pathRange]) as NSString).lastPathComponent
        }
        guard let pidRange = Range(match.range(at: 1), in: message) else { return nil }
        return "process \(message[pidRange])"
    }
}
