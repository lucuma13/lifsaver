import Foundation
import LifsaverCore

/// Mounts stalled volumes in two passes, so the password dialog only appears
/// when it buys something.
///
/// `diskutil mount` mounts external removable media as the logged-in user, so
/// the first pass runs in-process with no privileges and no prompt. Only if it
/// leaves a volume unmounted — the raw `/sbin/mount_*` fallback needs root — is
/// the bundled CLI re-run under the admin dialog, which rescans as root and
/// picks up whatever is left.
enum MountCoordinator {
    struct Outcome: Sendable {
        var unprivileged: CLIReport.Counts
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

        let counts = await mountUnprivileged(targets, scanner: scanner)
        guard counts.fail > 0 else { return Outcome(unprivileged: counts, escalated: nil) }
        return Outcome(unprivileged: counts, escalated: await EscalatedMount.run())
    }

    /// First pass: diskutil only, no escalation. A `.fail` here means "needs
    /// root", not "impossible".
    private static func mountUnprivileged(
        _ targets: [String], scanner: DiskScanner
    ) async -> CLIReport.Counts {
        let mounter = Mounter(scanner: scanner, allowRawFallback: false)
        var counts = CLIReport.Counts()
        for devId in targets {
            switch await mounter.execute(devId) {
            case .ok:
                counts.ok += 1
            case .fail:
                counts.fail += 1
            case .skip:
                counts.skip += 1
            }
        }
        return counts
    }
}
