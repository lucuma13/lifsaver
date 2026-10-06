import Foundation

// ---------------------------------------------------------------------------
// Debug capture
// ---------------------------------------------------------------------------

/// The fskitd snapshot is taken says which path collision refused the card, and
/// a mount attempt rewrites it. System log excerpts and process state follow in
/// the background.
public struct DebugCapture: Codable, Sendable {
    public enum Trigger: String, Codable, Sendable {
        /// The moment a card first counts as stalled, before any mount attempt.
        case stallDetected = "stall-detected"
        /// After a mount attempt on cards captured at their stall.
        case afterMount = "after-mount"
    }

    public var capturedAt: String
    public var trigger: Trigger
    /// The stalled devIds this capture is about.
    public var devices: [String]
    public var fskit: DiagnosticReport.FSKitState
    /// The `log show` window, e.g. `--start 2026-10-06 10:00:00`.
    public var logWindow = ""
    /// DiskArbitration, FSKit and lifs messages in that window. Paths and
    /// names read `<private>` unless a logging profile is installed; the
    /// order of messages, and which process went silent, survive.
    public var unifiedLog: [String] = []
    /// The last hour of renames, path changes, refused mounts and reader
    /// drop-outs: a ghost is often made long before the stall it causes.
    public var ghostHistory: [String] = []
    /// FSKit, mount and fsck processes; a `U` state is a hang.
    public var processes: [String] = []
    /// fskitd's pid and start time, so a crash-and-respawn shows across captures.
    public var fskitd = ""
    /// diskarbitrationd's description of each device (bus, device path,
    /// volume name), as last seen by the app.
    public var daDescriptions: [String: JSONValue] = [:]
}

/// Takes `DebugCapture`s. Never throws: like the report, every part that
/// cannot be gathered says `unavailable: ...` in its place.
public struct DebugCapturer: Sendable {
    /// `unifiedLog` keeps this many lines; DiskArbitration's session chatter
    /// (every Finder query) can fill a window on its own.
    public static let unifiedLogLineCap = 2000
    public static let ghostHistoryLineCap = 200
    /// Log lines from just before a card appeared show what DA did with it.
    static let logLead: TimeInterval = 5
    /// Disks present at launch "appeared" at launch; a window reaching back
    /// hours would make `log show` slow without adding anything.
    static let maxLogWindow: TimeInterval = 30 * 60
    /// `log show` reads the whole store for its window: slower than a query.
    static let logShowTimeout: TimeInterval = 60

    /// Leaves out diskarbitrationd's per-client callback and session lines:
    /// pure IPC plumbing, over half of its output on a busy Mac.
    static let unifiedLogPredicate =
        #"(process IN {"diskarbitrationd","fskitd","fskit_agent","com.apple.fskit.exfat","com.apple.fskit.msdos","#
        + #""mount_msdos","mount_exfat","fsck_msdos","fsck_exfat"} "#
        + #"OR subsystem IN {"com.apple.FSKit","com.apple.LiveFS","com.apple.DiskArbitration.diskarbitrationd"} "#
        + #"OR (process == "kernel" AND eventMessage CONTAINS "hardware connection lost")) "#
        + #"AND NOT (process == "diskarbitrationd" "#
        + #"AND (eventMessage CONTAINS "callback" OR eventMessage CONTAINS " session, id = "))"#

    static let ghostHistoryPredicate =
        #"process == "diskarbitrationd" AND (eventMessage CONTAINS "renamed disk" "#
        + #"OR eventMessage CONTAINS "volume name changed" OR eventMessage CONTAINS "volume path changed" "#
        + #"OR eventMessage CONTAINS "unable to mount") "#
        + #"OR (process == "kernel" AND eventMessage CONTAINS "hardware connection lost")"#

    /// Executable-name fragments of the processes a stall can hang in.
    static let processTokens = ["fskitd", "fskit_", "com.apple.fskit.", "mount_msdos", "mount_exfat", "fsck_"]

    private let runner: any ProcessRunning
    private let mountTable: any MountTableReading
    private let fskitSettings: any FSKitSettingsReading
    private let now: @Sendable () -> Date

    public init(
        runner: any ProcessRunning,
        mountTable: any MountTableReading = KernelMountTable(),
        fskitSettings: any FSKitSettingsReading = LivefsdSettingsFile(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.runner = runner
        self.mountTable = mountTable
        self.fskitSettings = fskitSettings
        self.now = now
    }

    /// fskitd's table and its ghosts, now. Synchronous so it lands before
    /// anything else can touch the table. `ghosts` are the scan's resolved
    /// ghosts, which supply each record's owner.
    public func snapshot(trigger: DebugCapture.Trigger, devices: [String], ghosts: [Ghost]) -> DebugCapture {
        DebugCapture(
            capturedAt: ISO8601DateFormatter().string(from: now()),
            trigger: trigger,
            devices: devices,
            fskit: .snapshot(settings: fskitSettings, mountTable: mountTable, owners: ghosts)
        )
    }

    /// The log excerpts and process state, added to a snapshot. `since` is when
    /// the earliest of its devices appeared (or, after a mount, when the stall
    /// was captured); nil falls back to the last two minutes.
    public func addingLogs(
        to snapshot: DebugCapture, since: Date?, daDescriptions: [String: JSONValue]
    ) async -> DebugCapture {
        let window = logWindow(since: since)
        async let unifiedLog = logShow(
            window + ["--info", "--debug", "--style", "compact", "--predicate", Self.unifiedLogPredicate],
            cap: Self.unifiedLogLineCap)
        async let ghostHistory = logShow(
            ["--last", "1h", "--info", "--style", "compact", "--predicate", Self.ghostHistoryPredicate],
            cap: Self.ghostHistoryLineCap)
        async let processes = processDump()
        async let fskitd = fskitdDump()

        var capture = snapshot
        capture.logWindow = window.joined(separator: " ")
        capture.unifiedLog = await unifiedLog
        capture.ghostHistory = await ghostHistory
        capture.processes = await processes
        capture.fskitd = await fskitd
        capture.daDescriptions = daDescriptions
        return capture
    }

    func logWindow(since: Date?) -> [String] {
        guard let since else { return ["--last", "2m"] }
        let start = max(since.addingTimeInterval(-Self.logLead), now().addingTimeInterval(-Self.maxLogWindow))
        return ["--start", Self.logTimestamp(start)]
    }

    /// The local-time form `log show --start` takes.
    static func logTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    /// Keeps the head and the tail of an over-long excerpt.
    static func capped(_ lines: [String], to cap: Int) -> [String] {
        guard lines.count > cap else { return lines }
        let head = cap / 2
        return Array(lines.prefix(head)) + ["... \(lines.count - cap) lines omitted ..."]
            + Array(lines.suffix(cap - head))
    }

    private func logShow(_ arguments: [String], cap: Int) async -> [String] {
        do {
            let result = try await runner.run("log", ["show"] + arguments, timeout: Self.logShowTimeout)
            let lines = result.stdoutText.split(separator: "\n").map(String.init)
            guard result.status == 0 || !lines.isEmpty else {
                let reason = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                return ["unavailable: 'log' exited with status \(result.status): \(reason)"]
            }
            return Self.capped(lines, to: cap)
        } catch {
            return ["unavailable: \(error)"]
        }
    }

    /// The header plus every process a stall can hang in. Matched on the
    /// executable alone: arguments mentioning fskitd (this capture's own `log
    /// show`) are not the process.
    private func processDump() async -> [String] {
        do {
            let result = try await runner.runChecked("ps", ["-axo", "pid,stat,etime,command"], timeout: queryTimeout)
            let lines = result.stdoutText.split(separator: "\n").map(String.init)
            return Array(lines.prefix(1))
                + lines.dropFirst().filter { line in
                    // pid, stat, etime, then the executable.
                    let fields = line.split(separator: " ")
                    guard fields.count > 3 else { return false }
                    let name = (String(fields[3]) as NSString).lastPathComponent
                    return Self.processTokens.contains { name.contains($0) }
                }
        } catch {
            return ["unavailable: \(error)"]
        }
    }

    private func fskitdDump() async -> String {
        do {
            let result = try await runner.runChecked("ps", ["-axo", "pid,lstart,command"], timeout: queryTimeout)
            let matches = result.stdoutText.split(separator: "\n").filter { line in
                line.split(separator: " ").contains { ($0 as NSString).lastPathComponent == "fskitd" }
            }
            return matches.isEmpty
                ? "not running"
                : matches.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
        } catch {
            return "unavailable: \(error)"
        }
    }
}

// ---------------------------------------------------------------------------
// Foundation values as JSON
// ---------------------------------------------------------------------------

extension JSONValue {
    /// Native JSON for a Core Foundation property graph JSONSerialization
    /// rejects: DiskArbitration descriptions carry CFURL, CFUUID and CFData.
    /// Anything else unknown is kept as its description.
    public init(foundation value: Any) {
        switch value {
        case let string as String:
            self = .string(string)
        case let number as NSNumber:
            // CFBoolean bridges to NSNumber too; only its type ID tells them apart.
            self =
                CFGetTypeID(number) == CFBooleanGetTypeID() ? .bool(number.boolValue) : .number(number.doubleValue)
        case let url as URL:
            self = .string(url.isFileURL ? url.path : url.absoluteString)
        case let uuid as UUID:
            self = .string(uuid.uuidString)
        case let data as Data:
            self = .string(data.prefix(256).map { String(format: "%02x", $0) }.joined())
        case let date as Date:
            self = .string(ISO8601DateFormatter().string(from: date))
        case let array as [Any]:
            self = .array(array.map(JSONValue.init(foundation:)))
        case let dictionary as [String: Any]:
            self = .object(dictionary.mapValues(JSONValue.init(foundation:)))
        default:
            let object = value as AnyObject
            let isUUID = CFGetTypeID(object) == CFUUIDGetTypeID()
            if isUUID, let uuid = CFUUIDCreateString(nil, unsafeDowncast(object, to: CFUUID.self)) {
                self = .string(uuid as String)
            } else {
                self = .string(String(describing: value))
            }
        }
    }
}
