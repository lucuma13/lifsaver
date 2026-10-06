import Foundation

// ---------------------------------------------------------------------------
// fskitd's persisted mount table
// ---------------------------------------------------------------------------

/// Where fskitd persists its mount table. World-readable; fskitd deletes the
/// file once no FSKit volume is mounted, so absence means "no records".
public let livefsdSettingsPath = "/Library/Application Support/livefsd/settings.plist"

/// One entry of fskitd's mount table, as persisted in `settings.plist`.
///
/// fskitd rejects any new mount whose path matches a live entry of another
/// volume (`-[mountTable preflightMountWithName:...]`), and diskarbitrationd
/// surfaces that as `unable to mount ... (status code 0x00000204)` - 516,
/// NSFileWriteFileExistsError. Renaming a mounted volume updates only
/// `displayName`; `mountedOn` keeps the original path, so the next card with
/// the old name is refused until the renamed volume is unmounted.
public struct FSKitMountRecord: Sendable, Equatable {
    public let displayName: String
    /// The path fskitd believes the volume is mounted on.
    public let mountedOn: String
    /// FSKit volume UUID (stored under fskitd's `volumeName` key).
    public let volumeUUID: String

    public init(displayName: String, mountedOn: String, volumeUUID: String) {
        self.displayName = displayName
        self.mountedOn = mountedOn
        self.volumeUUID = volumeUUID
    }
}

public struct FSKitSettingsError: Error, CustomStringConvertible {
    public let message: String

    public var description: String { message }
}

/// Seam over fskitd's settings file so tests can fake it.
public protocol FSKitSettingsReading: Sendable {
    /// The raw settings plist, or nil when the file does not exist.
    func settingsData() throws -> Data?
}

public struct LivefsdSettingsFile: FSKitSettingsReading {
    public let path: String

    public init(path: String = livefsdSettingsPath) {
        self.path = path
    }

    public func settingsData() throws -> Data? {
        do {
            return try Data(contentsOf: URL(fileURLWithPath: path))
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        }
    }
}

extension FSKitSettingsReading {
    /// Parsed mount records; empty when the file is absent.
    public func records() throws -> [FSKitMountRecord] {
        guard let data = try settingsData() else { return [] }
        return try FSKitMountRecord.parse(data)
    }
}

extension FSKitMountRecord {
    /// Parse the `mounts` array of fskitd's settings plist. Entries missing a
    /// `mountedOn` path are skipped - they cannot collide with a mount point.
    public static func parse(_ data: Data) throws -> [FSKitMountRecord] {
        guard
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
            let settings = plist as? [String: Any]
        else {
            throw FSKitSettingsError(message: "unreadable fskitd settings plist")
        }
        let mounts = settings["mounts"] as? [[String: Any]] ?? []
        return mounts.compactMap { mount in
            guard let mountedOn = mount["mountedOn"] as? String, !mountedOn.isEmpty else { return nil }
            return FSKitMountRecord(
                displayName: mount["displayName"] as? String ?? "",
                mountedOn: mountedOn,
                volumeUUID: mount["volumeName"] as? String ?? ""
            )
        }
    }
}

/// Records whose path is not a mount point in the kernel table: fskitd still
/// reserves the path, diskarbitrationd sees it free, so a card that gets that
/// path is refused with 0x204. A mount in flight is briefly recorded before
/// its kernel mount lands, so a single sighting is a hint, not proof.
public func ghostRecords(_ records: [FSKitMountRecord], mountTable: [MountEntry]) -> [FSKitMountRecord] {
    let mountPoints = Set(mountTable.map(\.mountPoint))
    return records.filter { !mountPoints.contains($0.mountedOn) }
}
