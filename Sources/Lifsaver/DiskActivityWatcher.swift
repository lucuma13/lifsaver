import DiskArbitration
import Foundation
import LifsaverKit

/// Watches diskarbitrationd's view of the world and fires a debounced
/// callback whenever it changes: a disk appears or disappears, or a volume
/// mounts or unmounts (`kDADiskDescriptionVolumePathKey`). Registration also
/// replays every disk already present, which doubles as the launch scan.
///
/// Debouncing matters twice over: one card insertion produces a burst of
/// events (the whole disk plus each partition), and diskarbitrationd may need
/// a few seconds - fsck runs first on dirty cards - before mounting a healthy
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

    /// When each disk appeared and diskarbitrationd's latest description of
    /// it, for debug captures.
    private struct DiskDetails {
        var appeared: Date?
        var description: JSONValue?
    }
    private var details: [String: DiskDetails] = [:]

    init(grace: TimeInterval = 5, onActivity: @escaping @MainActor () -> Void) {
        self.grace = grace
        self.onActivity = onActivity
        session = DASessionCreate(kCFAllocatorDefault)
        guard let session else {
            NSLog("lifsaver: DASessionCreate failed - proactive stall detection disabled")
            return
        }

        let context = Unmanaged.passUnretained(self).toOpaque()
        DARegisterDiskAppearedCallback(
            session, nil, { disk, context in onWatcher(context) { $0.diskChanged(disk, appeared: true) } }, context)
        DARegisterDiskDisappearedCallback(
            session, nil, { disk, context in onWatcher(context) { $0.diskDisappeared(disk) } }, context)
        DARegisterDiskDescriptionChangedCallback(
            session,
            nil,
            [kDADiskDescriptionVolumePathKey] as CFArray,
            { disk, _, context in onWatcher(context) { $0.diskChanged(disk, appeared: false) } },
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

    /// When the earliest of `devIds` (or its whole disk) appeared.
    func appeared(for devIds: [String]) -> Date? {
        Self.withWholeDisks(devIds).compactMap { details[$0]?.appeared }.min()
    }

    /// The latest description of each of `devIds` and its whole disk.
    func descriptions(for devIds: [String]) -> [String: JSONValue] {
        var result: [String: JSONValue] = [:]
        for name in Self.withWholeDisks(devIds) {
            result[name] = details[name]?.description
        }
        return result
    }

    func diskChanged(_ disk: DADisk, appeared: Bool) {
        if let name = Self.bsdName(disk) {
            var entry = details[name] ?? DiskDetails()
            if appeared { entry.appeared = Date() }
            entry.description = (DADiskCopyDescription(disk) as? [String: Any]).map(JSONValue.init(foundation:))
            details[name] = entry
        }
        poke()
    }

    func diskDisappeared(_ disk: DADisk) {
        if let name = Self.bsdName(disk) {
            details[name] = nil
        }
        poke()
    }

    private static func bsdName(_ disk: DADisk) -> String? {
        DADiskGetBSDName(disk).map { String(cString: $0) }
    }

    /// "disk4s1" brings "disk4": bus and device path describe the whole disk.
    private static func withWholeDisks(_ devIds: [String]) -> [String] {
        var names: [String] = []
        for devId in devIds {
            names.append(devId)
            if let slice = devId.range(of: #"s\d+$"#, options: .regularExpression) {
                names.append(String(devId[..<slice.lowerBound]))
            }
        }
        return names.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }
}

/// Shared entry of the C callbacks. DASessionSetDispatchQueue(.main) delivers
/// them on the main queue, so entering the actor is an assertion, not a hop.
private func onWatcher(_ context: UnsafeMutableRawPointer?, _ body: @MainActor (DiskActivityWatcher) -> Void) {
    guard let context else { return }
    let watcher = Unmanaged<DiskActivityWatcher>.fromOpaque(context).takeUnretainedValue()
    MainActor.assumeIsolated { body(watcher) }
}
