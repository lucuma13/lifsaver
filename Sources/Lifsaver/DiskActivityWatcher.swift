import DiskArbitration
import Foundation

/// Watches diskarbitrationd's view of the world and fires a debounced
/// callback whenever it changes: a disk appears or disappears, or a volume
/// mounts or unmounts (`kDADiskDescriptionVolumePathKey`). Registration also
/// replays every disk already present, which doubles as the launch scan.
///
/// Debouncing matters twice over: one card insertion produces a burst of
/// events (the whole disk plus each partition), and diskarbitrationd may need
/// a few seconds — fsck runs first on dirty cards — before mounting a healthy
/// card on its own. Scanning too eagerly would flag a card as stalled that
/// was about to mount by itself.
///
/// Lives for the app's lifetime; there is no unregister path.
@MainActor
final class DiskActivityWatcher {
    private let session: DASession?
    private let onActivity: @MainActor () -> Void
    private var pendingScan: Task<Void, Never>?

    /// Seconds between the last disk event and the rescan.
    private let grace: TimeInterval

    init(grace: TimeInterval = 5, onActivity: @escaping @MainActor () -> Void) {
        self.grace = grace
        self.onActivity = onActivity
        session = DASessionCreate(kCFAllocatorDefault)
        guard let session else {
            NSLog("lifsaver: DASessionCreate failed — proactive stall detection disabled")
            return
        }

        let context = Unmanaged.passUnretained(self).toOpaque()
        DARegisterDiskAppearedCallback(session, nil, { _, context in pokeWatcher(context) }, context)
        DARegisterDiskDisappearedCallback(session, nil, { _, context in pokeWatcher(context) }, context)
        DARegisterDiskDescriptionChangedCallback(
            session,
            nil,
            [kDADiskDescriptionVolumePathKey] as CFArray,
            { _, _, context in pokeWatcher(context) },
            context
        )
        DASessionSetDispatchQueue(session, .main)
    }

    /// Schedule the debounced rescan, pushing back one already pending.
    /// `delay` overrides the default grace (e.g. the longer fsck retry).
    func poke(after delay: TimeInterval? = nil) {
        pendingScan?.cancel()
        let seconds = delay ?? grace
        pendingScan = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.onActivity()
        }
    }
}

/// Shared body of the C callbacks. DASessionSetDispatchQueue(.main) delivers
/// them on the main queue, so entering the actor is an assertion, not a hop.
private func pokeWatcher(_ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let watcher = Unmanaged<DiskActivityWatcher>.fromOpaque(context).takeUnretainedValue()
    MainActor.assumeIsolated { watcher.poke() }
}
