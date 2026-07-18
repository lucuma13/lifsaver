import Foundation

public enum MountOutcome: String, Sendable {
    case ok
    case skip
    case fail
}

// ---------------------------------------------------------------------------
// File operations seam (mount-point directory lifecycle)
// ---------------------------------------------------------------------------

public protocol FileOperating: Sendable {
    func createDirectory(at path: String) throws
    /// Best-effort removal that only succeeds on an EMPTY directory (rmdir
    /// semantics) — must never delete data that landed under a mount point.
    func removeEmptyDirectory(at path: String)
}

public struct DefaultFileOperations: FileOperating {
    public init() {}

    public func createDirectory(at path: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    public func removeEmptyDirectory(at path: String) {
        _ = path.withCString { rmdir($0) }
    }
}

// ---------------------------------------------------------------------------
// Mounter
// ---------------------------------------------------------------------------

/// Executes the mount sequence for stalled partitions. Read-only questions
/// (mount table, fsck, filesystem type) go through the scanner it wraps.
public struct Mounter: Sendable {
    public let scanner: DiskScanner
    public let fileOps: any FileOperating
    /// The raw `/sbin/mount_*` binaries and their mount-point directories need
    /// root; `diskutil mount` usually does not. Set false for an unprivileged
    /// first pass, so a password is only ever asked for the volumes diskutil
    /// alone could not mount.
    public let allowRawFallback: Bool

    public init(
        scanner: DiskScanner,
        fileOps: any FileOperating = DefaultFileOperations(),
        allowRawFallback: Bool = true
    ) {
        self.scanner = scanner
        self.fileOps = fileOps
        self.allowRawFallback = allowRawFallback
    }

    var runner: any ProcessRunning { scanner.runner }
    var console: Console { scanner.console }
    var verbose: Bool { scanner.verbose }

    /// Orchestrate the full mount sequence for a single device identifier.
    ///
    /// Strategy (macOS Tahoe / LIFS-aware):
    ///   1. Re-confirm the device is still unmounted (race-condition guard).
    ///   2. Stand down if macOS is mid consistency check on the device.
    ///   3. Try `diskutil mount` — preferred; handles LIFS sandboxing.
    ///   4. Fall back to raw mount binaries if diskutil fails.
    public func execute(_ devId: String) async -> MountOutcome {
        if verbose {
            console.out("\nTarget: /dev/\(devId)")
        }

        // Re-query live mount table immediately before acting (race guard). nil
        // (table unreadable) proceeds: diskutil mount on an already mounted
        // volume is a harmless no-op, skipping a stalled one is not.
        if scanner.isCurrentlyMounted(devId) == true {
            console.out("  SKIPPED — /dev/\(devId) became mounted since scan.")
            return .skip
        }

        // Never fight a repair in progress — wait for macOS to finish or bail out.
        if await scanner.isFsckActive(devId) {
            console.out("  SKIPPED — macOS is running a consistency check (fsck) on /dev/\(devId).")
            console.out("  Let it finish and mount again from the menu; mounting mid-check risks corrupting the card.")
            return .skip
        }

        let fsType = await scanner.partitionFSType(devId)
        if verbose && !fsType.isEmpty {
            console.out("  Detected filesystem: \(fsType)")
        }

        if await attemptMounts(devId, fsType: fsType) {
            return .ok
        }

        if allowRawFallback {
            console.out("  CRITICAL ERROR: All mount strategies rejected /dev/\(devId)")
        } else if verbose {
            console.out("  diskutil mount rejected /dev/\(devId) — needs elevated privileges.")
        }
        return .fail
    }

    /// Try `diskutil mount` first (preferred; handles LIFS sandboxing), then
    /// fall back to raw mount binaries.  Verifies against the live mount table
    /// after each attempt; when the table cannot be read (nil), the mount
    /// binary's zero exit stands — an unreadable table must not turn a
    /// successful mount into a spurious failure (and, one level up, into an
    /// unwarranted admin password prompt).
    func attemptMounts(_ devId: String, fsType: String) async -> Bool {
        if verbose {
            console.out("  Attempting diskutil mount...")
        }
        if await diskutilMount(devId), scanner.isCurrentlyMounted(devId) != false {
            if verbose {
                let location = scanner.mountPoint(of: devId)
                console.out("  SUCCESS via diskutil → \(location.isEmpty ? "(see /Volumes)" : location)")
            }
            return true
        }

        guard allowRawFallback else { return false }

        if verbose {
            console.out("  diskutil mount failed; falling back to raw mount binaries...")
        }
        if await rawMount(devId, fsType: fsType) {
            if scanner.isCurrentlyMounted(devId) != false {
                if verbose {
                    console.out("  SUCCESS via raw mount → \(rawMountPoint(devId))")
                }
                return true
            }
            // The mount binary exited 0 but the volume never appeared in the
            // mount table — reclaim the mount-point directory it was given.
            fileOps.removeEmptyDirectory(at: rawMountPoint(devId))
        }

        return false
    }

    /// One pass over `targets`: mount each and tally, collecting the mount
    /// points of the volumes this pass mounted. Shared by the unprivileged
    /// first pass and the escalated root helper so their tallies can never
    /// drift.
    public struct PassResult: Sendable {
        public var counts = MountReport.Counts()
        public var mounted: [MountReport.MountedVolume] = []

        public init() {}
    }

    public func mountAll(_ targets: [String]) async -> PassResult {
        var result = PassResult()
        for devId in targets {
            switch await execute(devId) {
            case .ok:
                result.counts.ok += 1
                result.mounted.append(.init(device: devId, mountPoint: scanner.mountPoint(of: devId)))
            case .fail:
                result.counts.fail += 1
            case .skip:
                result.counts.skip += 1
            }
        }
        return result
    }

    /// Where rawMount grafts the volume — the raw binaries need an explicit,
    /// pre-created mount point (diskutil manages its own under /Volumes).
    func rawMountPoint(_ devId: String) -> String {
        "/Volumes/Camera_Data_\(devId)"
    }

    /// Attempt mount via `diskutil mount`, the preferred path on macOS Tahoe.
    /// diskutil handles filesystem detection, SIP/LIFS sandboxing, and
    /// mount-point creation automatically.
    func diskutilMount(_ devId: String) async -> Bool {
        let result: ProcessResult
        do {
            result = try await runner.run("diskutil", ["mount", devId], timeout: mountTimeout)
        } catch {
            logError("diskutil", error)
            return false
        }
        logStderr("diskutil", result)
        return result.status == 0
    }

    /// Verbose diagnostic logging shared by every mount attempt, so the
    /// diskutil and raw-binary paths always trace identically.
    private func logStderr(_ label: String, _ result: ProcessResult) {
        guard verbose, !result.stderr.isEmpty else { return }
        console.err("  [\(label) stderr] \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
    }

    private func logError(_ label: String, _ error: any Error) {
        guard verbose else { return }
        console.err("  [\(label) error] \(error)")
    }

    /// Fallback: use low-level mount binaries when diskutil mount is
    /// unavailable or returns an error.  Mount-point directory is created and
    /// cleaned up on failure.
    ///
    /// Tries exFAT first (most modern cards), then FAT32/MSDOS.
    func rawMount(_ devId: String, fsType: String) async -> Bool {
        let devPath = "/dev/\(devId)"
        let mountPoint = rawMountPoint(devId)

        do {
            try fileOps.createDirectory(at: mountPoint)
        } catch {
            if verbose {
                console.err("  [mount-point error] \(error)")
            }
            return false
        }

        // Determine mount sequence: honour detected fsType when available
        let candidates: [[String]]
        if ["msdos", "fat", "fat32"].contains(fsType) {
            candidates = [
                ["/sbin/mount_msdos", devPath, mountPoint],
                ["/sbin/mount_exfat", devPath, mountPoint],
            ]
        } else {
            // Default: exFAT first (CFast, SDXC), then FAT32 (older SDHC)
            candidates = [
                ["/sbin/mount_exfat", devPath, mountPoint],
                ["/sbin/mount_msdos", devPath, mountPoint],
            ]
        }

        for command in candidates {
            let name = (command[0] as NSString).lastPathComponent
            let result: ProcessResult
            do {
                result = try await runner.run(command[0], Array(command.dropFirst()), timeout: mountTimeout)
            } catch {
                // Missing binary (removed in newer macOS) or a hung card reader:
                // move on to the next candidate rather than crashing.
                logError(name, error)
                continue
            }
            logStderr(name, result)
            if result.status == 0 {
                return true
            }
        }

        // Both failed — clean up the empty directory we created
        fileOps.removeEmptyDirectory(at: mountPoint)

        return false
    }
}
