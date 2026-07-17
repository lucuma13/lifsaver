import Foundation

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/// Partition "Content" values reported by `diskutil list -plist`. These name
/// MBR/GPT partition types, not filesystems:
public let externalFSAllowlist: [String] = [
    "DOS_FAT_32",  // MBR type 0x0B — FAT32 as formatted by macOS Disk Utility
    "Windows_FAT_32",  // MBR type 0x0C (FAT32 LBA) — FAT32 as formatted by Windows / SD Formatter
    "Windows_NTFS",  // MBR type 0x07 — shared by exFAT and NTFS; SDXC cards formatted in-camera report this
    "Microsoft Basic Data",  // GPT Basic Data GUID — any FAT32/exFAT/NTFS partition on a GUID-partitioned card
    "exFAT",  // filesystem personality names
    "ExFAT",  // values (exFAT reports Windows_NTFS or Microsoft Basic Data)
]

// Blocklist: EFI, recovery, and Apple container types.
// Redundant with the allowlist today, but kept as a second interlock:
// the allowlist uses substring matching and gets edited — a future broad
// token must still never expose Apple/EFI system partitions.
let blockedContentTokens = [
    "EFI",
    "Apple_APFS",
    "Apple_HFS",
    "Apple_Boot",
    "Apple_Recovery",
    "Apple_CoreStorage",
]

public let separatorLine = String(repeating: "-", count: 56)

// Read-only queries (diskutil info, pgrep) should return near-instantly;
// mount attempts can legitimately stall on slow card readers, so they get longer.
public let queryTimeout: TimeInterval = 30
public let mountTimeout: TimeInterval = 120

public struct DiskUtilError: Error, CustomStringConvertible {
    public let message: String

    public init(message: String) {
        self.message = message
    }

    public var description: String { message }
}

// ---------------------------------------------------------------------------
// Scanner
// ---------------------------------------------------------------------------

/// Read-only disk introspection: the kernel mount table, `diskutil` plists,
/// and the fsck stand-down check. Holds its collaborators once so call sites
/// don't thread runner/console through every call.
public struct DiskScanner: Sendable {
    public let runner: any ProcessRunning
    public let mountTable: any MountTableReading
    public let console: Console
    public let verbose: Bool

    public init(
        runner: any ProcessRunning,
        mountTable: any MountTableReading = LiveMountTable(),
        console: Console = .standard,
        verbose: Bool = false
    ) {
        self.runner = runner
        self.mountTable = mountTable
        self.console = console
        self.verbose = verbose
    }

    // --- mount table --------------------------------------------------------

    /// The set of currently-mounted device paths (e.g. {"/dev/disk4s1", ...}),
    /// from a fresh kernel snapshot. Virtual filesystems (devfs, autofs maps)
    /// are excluded.
    public func activeMounts() -> Set<String> {
        do {
            return Set(try mountTable.entries().map(\.device).filter { $0.hasPrefix("/dev/") })
        } catch {
            console.err("WARNING: Could not read mount table: \(error)")
            return []
        }
    }

    /// Re-query the live mount table for a single device.
    /// Always takes a fresh snapshot — never relies on a cached set.
    public func isCurrentlyMounted(_ devId: String) -> Bool {
        activeMounts().contains("/dev/\(devId)")
    }

    /// The current mount point for a device, or "" when it is not mounted
    /// (or the table cannot be read).
    public func mountPoint(of devId: String) -> String {
        let devPath = "/dev/\(devId)"
        let entries = (try? mountTable.entries()) ?? []
        return entries.first { $0.device == devPath }?.mountPoint ?? ""
    }

    // --- process probes ------------------------------------------------------

    /// Detect whether macOS is running a background consistency check against
    /// the device.  diskarbitrationd silently spawns fsck_exfat / fsck_msdos on
    /// dirty cards before deciding whether to mount them; forcing a mount while
    /// that repair is in flight races it and can corrupt the card.
    ///
    /// Matches both /dev/diskXsY and the raw /dev/rdiskXsY node fsck actually
    /// opens, without matching longer identifiers (disk4s1 ≠ disk4s10).
    public func isFsckActive(_ devId: String) async -> Bool {
        let result: ProcessResult
        do {
            // pgrep exits 1 when nothing matches — not an error
            result = try await runner.run("pgrep", ["-fl", "fsck"], timeout: queryTimeout)
        } catch {
            return false
        }
        let pattern = "\\br?" + NSRegularExpression.escapedPattern(for: devId) + "\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        return result.stdoutText.split(separator: "\n").contains { line in
            let string = String(line)
            let range = NSRange(string.startIndex..., in: string)
            return regex.firstMatch(in: string, range: range) != nil
        }
    }

    // --- diskutil ------------------------------------------------------------

    /// Retrieve all physical partition details via structured plist data.
    public func diskData() async throws -> [String: Any] {
        let result: ProcessResult
        do {
            result = try await runner.runChecked("diskutil", ["list", "-plist"], timeout: queryTimeout)
        } catch {
            throw DiskUtilError(message: "Failed to query diskutil: \(error)")
        }
        guard
            let plist = try? PropertyListSerialization.propertyList(from: result.stdout, format: nil),
            let data = plist as? [String: Any]
        else {
            throw DiskUtilError(message: "Failed to query diskutil: unreadable plist output")
        }
        return data
    }

    /// Ask diskutil for the actual filesystem type of a partition so we can
    /// choose the right mount binary without trial-and-error.
    ///
    /// Returns a lowercase string such as "exfat", "msdos", "hfs", or "" if the
    /// information is unavailable.
    public func partitionFSType(_ devId: String) async -> String {
        guard
            let result = try? await runner.runChecked("diskutil", ["info", "-plist", devId], timeout: queryTimeout),
            let plist = try? PropertyListSerialization.propertyList(from: result.stdout, format: nil),
            let info = plist as? [String: Any]
        else { return "" }
        // "FilesystemType" is the canonical key; fall back to content hint.
        // An empty string counts as absent — the fallback must still apply.
        let fsType = info["FilesystemType"] as? String
        let content = info["Content"] as? String
        let fs = [fsType, content].compactMap { $0 }.first { !$0.isEmpty } ?? ""
        return fs.lowercased()
    }

    // --- partition filtering ---------------------------------------------------

    /// Whole-disk externality check via `diskutil info -plist`.
    ///
    /// `diskutil list -plist` carries no hardware-location key (its per-disk
    /// entries are just Content / DeviceIdentifier / OSInternal / Size, and
    /// OSInternal does not mean "internal hardware"), so this must be a
    /// separate per-disk query. Two signals, either suffices:
    ///
    ///   - `Internal == false` — device sits on an external bus
    ///   - `RemovableMediaOrExternalDevice == true` — second signal covering
    ///     card readers whose USB bridges misreport `Internal`, and built-in
    ///     SD slots (removable media on an internal bus)
    ///
    /// Fails closed: an unreadable plist or missing keys count as internal.
    public func isExternalHardware(_ diskID: String) async -> Bool {
        guard
            let result = try? await runner.runChecked("diskutil", ["info", "-plist", diskID], timeout: queryTimeout),
            let plist = try? PropertyListSerialization.propertyList(from: result.stdout, format: nil),
            let info = plist as? [String: Any]
        else { return false }
        return info["Internal"] as? Bool == false
            || info["RemovableMediaOrExternalDevice"] as? Bool == true
    }

    /// Walk the plist returned by `diskutil list -plist` and return device
    /// identifiers (e.g. ["disk4s1"]) that are:
    ///
    ///   - on external hardware (see `isExternalHardware`)
    ///   - a recognised camera-card filesystem type
    ///   - NOT in `activeMounts` (one consistent snapshot, taken by the caller)
    ///
    /// EFI system partitions and Apple_APFS / Apple_HFS containers are
    /// explicitly excluded.
    public func filterTargetPartitions(_ diskData: [String: Any], activeMounts: Set<String>) async -> [String] {
        var targets: [String] = []

        let disks = diskData["AllDisksAndPartitions"] as? [[String: Any]] ?? []
        for disk in disks {
            let partitions = disk["Partitions"] as? [[String: Any]] ?? []

            // Content checks first, so `diskutil info` only runs for disks
            // that actually carry camera-card-like partitions.
            let candidates = partitions.filter(isCandidatePartition)
            guard !candidates.isEmpty else { continue }

            // Strict boundary: internal disks are never touched.
            let diskID = disk["DeviceIdentifier"] as? String ?? ""
            guard !diskID.isEmpty, await isExternalHardware(diskID) else {
                if verbose {
                    console.out("  Skipping \(diskID.isEmpty ? "unidentified disk" : diskID) — not external hardware.")
                }
                continue
            }

            for partition in candidates {
                let devId = partition["DeviceIdentifier"] as? String ?? ""

                // Safety gate: skip anything already in the mount table
                if activeMounts.contains("/dev/\(devId)") {
                    if verbose {
                        console.out("  Skipping \(devId) — already mounted.")
                    }
                    continue
                }

                targets.append(devId)
            }
        }

        return targets
    }

    /// Content gate for a single partition, with a logged reason for every
    /// rejection so `--verbose` runs and diagnostic reports can replay the
    /// decision.
    private func isCandidatePartition(_ partition: [String: Any]) -> Bool {
        let contentType = partition["Content"] as? String ?? ""
        let devId = partition["DeviceIdentifier"] as? String ?? ""

        guard !devId.isEmpty else { return false }

        if blockedContentTokens.contains(where: { contentType.contains($0) }) {
            if verbose {
                console.out("  Skipping \(devId) — system partition (\(contentType)).")
            }
            return false
        }

        // Allowlist: recognised camera-card payload types
        guard externalFSAllowlist.contains(where: { contentType.contains($0) }) else {
            if verbose {
                let shown = contentType.isEmpty ? "(empty)" : contentType
                console.out("  Skipping \(devId) — Content \(shown) is not camera-card-like.")
            }
            return false
        }
        return true
    }

    /// One-call read-only scan: disk data + a fresh mount-table snapshot → targets.
    public func scanTargets() async throws -> [String] {
        let data = try await diskData()
        return await filterTargetPartitions(data, activeMounts: activeMounts())
    }
}
