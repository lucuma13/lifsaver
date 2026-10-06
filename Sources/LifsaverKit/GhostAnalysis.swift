import Foundation

// ---------------------------------------------------------------------------
// Ghost analysis
// ---------------------------------------------------------------------------

/// Where diskarbitrationd puts volume mount points.
public let volumesRoot = "/Volumes"

/// The label diskarbitrationd (and `diskutil info`) gives a volume without
/// one. Localized by macOS; only the English name is handled here.
public let untitledVolumeLabel = "Untitled"

/// An fskitd record whose path is not a mount point (see `ghostRecords`),
/// together with the mounted volume that owns it.
///
/// A volume renamed while mounted moves to a new mount point, but fskitd keeps
/// the old one reserved: the owner is still mounted, and unmounting it is what
/// releases the path. With no owner the record outlived its volume.
public struct Ghost: Sendable, Equatable {
    public let record: FSKitMountRecord
    /// The owner's device identifier (e.g. "disk6s1"), or nil when no mounted
    /// volume owns the record.
    public let ownerDevice: String?
    public let ownerMountPoint: String?

    public init(record: FSKitMountRecord, ownerDevice: String? = nil, ownerMountPoint: String? = nil) {
        self.record = record
        self.ownerDevice = ownerDevice
        self.ownerMountPoint = ownerMountPoint
    }

    public var isLeak: Bool { ownerDevice == nil }

    /// What the user knows the owner as: its current name, which fskitd does
    /// track across a rename.
    public var ownerName: String {
        if !record.displayName.isEmpty { return record.displayName }
        if let ownerMountPoint { return (ownerMountPoint as NSString).lastPathComponent }
        return "a previous card"
    }

    /// The label of the cards this path is offered to, read off the path the
    /// way diskarbitrationd built it.
    public var blockedLabel: String { label(fromMountPath: record.mountedOn) }
}

/// The mount point diskarbitrationd gives a volume labelled `label`: the first
/// of `/Volumes/<label>`, `/Volumes/<label> 1` ... `<label> 99` that does not
/// exist yet. `/` is not allowed in a path component, so disk arbitration
/// writes it as `:`. nil when every candidate is taken.
public func nextMountPath(forLabel label: String, exists: (String) -> Bool) -> String? {
    let base = "\(volumesRoot)/\(label.replacingOccurrences(of: "/", with: ":"))"
    if !exists(base) { return base }
    return (1...99).lazy.map { "\(base) \($0)" }.first { !exists($0) }
}

/// The label a mount path was derived from: its last component with one
/// trailing " <digits>" suffix stripped. A label that itself ends in digits
/// ("Card 2") reads wrong here; for a stalled card the real label is known
/// and used instead (`DiskScanner.explainStall`).
public func label(fromMountPath path: String) -> String {
    let name = (path as NSString).lastPathComponent.replacingOccurrences(of: ":", with: "/")
    guard let space = name.lastIndex(of: " "), space > name.startIndex else { return name }
    let digits = name[name.index(after: space)...]
    guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return name }
    return String(name[..<space])
}

/// Whether the next card carrying the ghost's label would be refused: true
/// iff diskarbitrationd would pick the ghost's path for it. A ghost on
/// `/Volumes/L 2` is harmless while `/Volumes/L` or `/Volumes/L 1` is free.
public func isBlocking(_ record: FSKitMountRecord, exists: (String) -> Bool) -> Bool {
    guard (record.mountedOn as NSString).deletingLastPathComponent == volumesRoot else { return false }
    return nextMountPath(forLabel: label(fromMountPath: record.mountedOn), exists: exists) == record.mountedOn
}

/// A mounted volume as `diskutil info` describes it, for matching against
/// fskitd's records.
public struct MountedVolume: Sendable, Equatable {
    public let device: String
    public let mountPoint: String
    public let volumeUUID: String
    public let volumeName: String

    public init(device: String, mountPoint: String, volumeUUID: String, volumeName: String) {
        self.device = device
        self.mountPoint = mountPoint
        self.volumeUUID = volumeUUID
        self.volumeName = volumeName
    }
}

/// Pair each ghost record with its owner. fskitd's `volumeName` is the
/// owner's `VolumeUUID`; a clone of an already mounted card gets a random
/// FSKit UUID instead, so a name match is the fallback.
public func resolveGhosts(_ records: [FSKitMountRecord], volumes: [MountedVolume]) -> [Ghost] {
    records.map { record in
        let byUUID = volumes.first {
            !record.volumeUUID.isEmpty && $0.volumeUUID.caseInsensitiveCompare(record.volumeUUID) == .orderedSame
        }
        let byName = volumes.first {
            !record.displayName.isEmpty
                && ($0.volumeName == record.displayName
                    || ($0.mountPoint as NSString).lastPathComponent == record.displayName)
        }
        guard let owner = byUUID ?? byName else { return Ghost(record: record) }
        return Ghost(record: record, ownerDevice: owner.device, ownerMountPoint: owner.mountPoint)
    }
}

/// Why a specific card stalled: its label sends it to a path a ghost holds.
public struct StallExplanation: Sendable, Equatable {
    public let devId: String
    public let label: String
    public let ghost: Ghost

    public init(devId: String, label: String, ghost: Ghost) {
        self.devId = devId
        self.label = label
        self.ghost = ghost
    }
}

extension DiskScanner {
    /// Every current ghost with its owner resolved. Costs one `diskutil info`
    /// per mounted volume, and nothing at all while there is no ghost.
    public func ghosts() async -> [Ghost] {
        let records = ghostFSKitMounts()
        guard !records.isEmpty else { return [] }
        let entries = ((try? mountTable.entries()) ?? []).filter {
            $0.device.hasPrefix("/dev/") && $0.mountPoint.hasPrefix(volumesRoot + "/")
        }
        let volumes = await withTaskGroup(of: (Int, MountedVolume?).self) { group in
            for (index, entry) in entries.enumerated() {
                group.addTask {
                    let devId = String(entry.device.dropFirst("/dev/".count))
                    guard let info = await diskInfo(devId) else { return (index, nil) }
                    return (
                        index,
                        MountedVolume(
                            device: devId, mountPoint: entry.mountPoint,
                            volumeUUID: info["VolumeUUID"] as? String ?? "",
                            volumeName: info["VolumeName"] as? String ?? "")
                    )
                }
            }
            var results = [MountedVolume?](repeating: nil, count: entries.count)
            for await (index, volume) in group {
                results[index] = volume
            }
            return results.compactMap { $0 }
        }
        return resolveGhosts(records, volumes: volumes)
    }

    /// Whether the ghost would refuse the next card with its label, judged
    /// against the live /Volumes.
    public func isBlocking(_ ghost: Ghost) -> Bool {
        LifsaverKit.isBlocking(ghost.record, exists: pathExists)
    }

    /// The label diskarbitrationd mounts a device under. An unlabelled card
    /// reports "Untitled", which is also what disk arbitration uses.
    public func volumeLabel(_ devId: String) async -> String? {
        guard let info = await diskInfo(devId) else { return nil }
        let name = info["VolumeName"] as? String ?? ""
        return name.isEmpty ? untitledVolumeLabel : name
    }

    /// The ghost record on the path diskarbitrationd would mount `devId` at,
    /// if any: `diskutil mount` on that device is bound to be refused. Reads
    /// no device info while there is no ghost at all.
    public func ghostRecord(blocking devId: String) async -> (label: String, record: FSKitMountRecord)? {
        let records = ghostFSKitMounts()
        guard
            !records.isEmpty,
            let label = await volumeLabel(devId),
            let path = nextMountPath(forLabel: label, exists: pathExists),
            let record = records.first(where: { $0.mountedOn == path })
        else { return nil }
        return (label, record)
    }

    /// Explain a stalled card: the ghost (with its owner) holding the path it
    /// would mount at, or nil when its stall has another cause.
    public func explainStall(_ devId: String) async -> StallExplanation? {
        guard let (label, record) = await ghostRecord(blocking: devId) else { return nil }
        let ghost = await ghosts().first { $0.record == record } ?? Ghost(record: record)
        return StallExplanation(devId: devId, label: label, ghost: ghost)
    }
}
