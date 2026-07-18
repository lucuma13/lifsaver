import LifsaverKit

/// Mounts stalled volumes in two passes, so the password dialog only appears
/// when it buys something.
///
/// `diskutil mount` mounts external removable media as the logged-in user, so
/// the first pass runs in-process with no privileges and no prompt. Only if it
/// leaves a volume unmounted — the raw `/sbin/mount_*` fallback needs root —
/// does the app re-run its own binary under the admin dialog, which rescans as
/// root and picks up whatever is left.
enum MountCoordinator {
    struct Outcome: Sendable {
        var unprivileged: MountReport.Counts
        /// nil when the first pass left nothing for root to do — the case where
        /// the user is never asked for a password at all.
        var escalated: EscalatedMountOutcome?
    }

    static func run(scanner: DiskScanner) async -> Outcome {
        let targets: [String]
        do {
            targets = try await scanner.scanTargets()
        } catch {
            // Escalating would only reach the same failing scan under root, so
            // report it rather than spend a password dialog on it.
            return Outcome(unprivileged: .init(), escalated: .error("scan failed: \(error)"))
        }

        // First pass: diskutil only, no escalation. A `.fail` here means
        // "needs root", not "impossible".
        let counts = await Mounter(scanner: scanner, allowRawFallback: false).mountAll(targets).counts
        guard counts.fail > 0 else { return Outcome(unprivileged: counts, escalated: nil) }
        return Outcome(unprivileged: counts, escalated: await EscalatedMount.run())
    }
}
