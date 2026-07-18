import Darwin
import Foundation

/// One row of the kernel VFS mount table.
public struct MountEntry: Sendable, Equatable {
    /// What is mounted, e.g. "/dev/disk4s1" (or "devfs", "map auto_home" for virtual filesystems).
    public let device: String
    /// Where it is mounted, e.g. "/Volumes/CARD".
    public let mountPoint: String

    public init(device: String, mountPoint: String) {
        self.device = device
        self.mountPoint = mountPoint
    }
}

/// Seam over the kernel mount table so tests can fake it. Every call must
/// return a fresh snapshot — callers use this as a race guard around mounts.
public protocol MountTableReading: Sendable {
    func entries() throws -> [MountEntry]
}

/// Live kernel mount table via getmntinfo_r_np(3) — the same data `mount`
/// prints, without a subprocess or text parsing. The _r variant is
/// thread-safe; the plain getmntinfo shares one static buffer per process.
public struct LiveMountTable: MountTableReading {
    public init() {}

    public func entries() throws -> [MountEntry] {
        // MNT_NOWAIT returns current table *membership* without re-statfs'ing
        // every filesystem — the refresh could hang on a dead network mount,
        // and the names we need are not statfs-derived.
        var table: UnsafeMutablePointer<statfs>?
        let count = getmntinfo_r_np(&table, MNT_NOWAIT)
        guard count > 0, let table else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { free(table) }
        return (0..<Int(count)).map { index in
            MountEntry(
                device: string(fromFixedField: table[index].f_mntfromname),
                mountPoint: string(fromFixedField: table[index].f_mntonname)
            )
        }
    }

    /// Decode a fixed-size NUL-terminated CChar tuple field (statfs exposes
    /// its char arrays to Swift as tuples).
    private func string<Field>(fromFixedField field: Field) -> String {
        withUnsafeBytes(of: field) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }
}
