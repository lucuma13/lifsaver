import Foundation
import os

#if arch(arm64)
    private let buildArchitecture = "arm64"
#elseif arch(x86_64)
    private let buildArchitecture = "x86_64"
#else
    private let buildArchitecture = "unknown"
#endif

/// Where diagnostic reports should be emailed. Assembled at runtime from
/// fragments so it never appears verbatim in the repository, on rendered
/// GitHub pages, or in the shipped binary's string table.
public let lifsaverSupportEmail = ["alterluigi", "+", "debug", "@", "gma", "il", ".", "com"].joined()

/// A parsed JSON value, so third-party output that is already structured
/// (`diskutil`'s plists) can be embedded as native, queryable JSON  — keeping
/// the whole report one uniform document.
public enum JSONValue: Codable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Bool before Double: JSON `true` must not be read as a number.
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "unsupported JSON value"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }
    public var stringValue: String? { if case .string(let value) = self { return value } else { return nil } }
    public var boolValue: Bool? { if case .bool(let value) = self { return value } else { return nil } }
}

/// Parses `diskutil`'s plist output into native JSON so the report stays one
/// uniform structured document. Falls back to the raw text (itself valid JSON,
/// as a string) when the output is not a parseable plist — an `unavailable:`
/// marker or malformed output — which is exactly the case where seeing the raw
/// bytes is what you want.
func plistAsJSON(_ text: String) -> JSONValue {
    guard
        let object = try? PropertyListSerialization.propertyList(from: Data(text.utf8), format: nil),
        JSONSerialization.isValidJSONObject(object),
        let data = try? JSONSerialization.data(withJSONObject: object),
        let value = try? JSONDecoder().decode(JSONValue.self, from: data)
    else {
        return .string(text)
    }
    return value
}

/// Diagnostic report, so a missed or unmountable card can be debugged. The
/// app's own fields (metadata, detected targets, the mount table) and
/// `diskutil`'s plist output alike are native JSON, so every value is directly
/// queryable. The plists are parsed generically, so no keys are dropped.
public struct DiagnosticReport: Codable, Sendable {
    public struct Meta: Codable, Sendable {
        public var generated: String
        public var version: String
        public var macOS: String
        public var architecture: String
        /// What the report contains, so a reader knows what they are sharing.
        public var privacyNote: String
    }

    /// One detected target and the two facts the mounter branches on.
    public struct Target: Codable, Sendable {
        public var device: String
        public var fsType: String
        public var fsckActive: Bool
    }

    /// The verbose re-scan run at report time. `consoleOutput` is what the
    /// scanner said as it decided; `error` is set instead of `targets` when the
    /// scan itself threw. This is sampled *now*, not when the problem occurred —
    /// `liveLog` holds what happened then.
    public struct ScanTrace: Codable, Sendable {
        public var consoleOutput: [String] = []
        public var targets: [Target] = []
        public var error: String?
    }

    public struct MountTableEntry: Codable, Sendable {
        public var device: String
        public var mountPoint: String
    }

    public struct DiskInfo: Codable, Sendable {
        public var device: String
        /// `diskutil info -plist` parsed to native JSON, or an `unavailable:`
        /// string when it could not be read.
        public var info: JSONValue
    }

    public var meta: Meta
    /// The reporter's own description of what went wrong; nil when omitted.
    public var userNote: String?
    /// The app's recent scan/mount outcomes.
    public var appEvents: [String]
    /// Console output recorded live during those past scans and mount attempts.
    public var liveLog: [String]
    public var scanTrace: ScanTrace
    /// The kernel mount table, or `mountTableError` when it could not be read.
    public var mountTable: [MountTableEntry]
    public var mountTableError: String?
    /// `pgrep -fl fsck` lines; empty means none running.
    public var fsckProcesses: [String]
    /// `diskutil list -plist` parsed to native JSON, or an `unavailable:`
    /// string when it could not be read.
    public var diskutilList: JSONValue
    public var diskInfo: [DiskInfo]

    /// Pretty-printed, stable-key JSON — the form written to disk and emailed.
    public func jsonString() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else {
            return "{\"error\":\"could not encode diagnostic report\"}"
        }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Pre-addressed mailto: draft for sending a report. mailto cannot attach
/// files, so the body asks the sender to attach the saved report themselves.
public func lifsaverReportMailtoURL(reportFilename: String) -> URL? {
    var components = URLComponents()
    components.scheme = "mailto"
    components.path = lifsaverSupportEmail
    components.queryItems = [
        URLQueryItem(name: "subject", value: "lifsaver diagnostic report"),
        URLQueryItem(name: "body", value: "Please attach \(reportFilename) to this email before sending.\n\n"),
    ]
    return components.url
}

/// Assembles the plain-text diagnostic report.
///
/// Read-only: it re-runs the scanner verbosely and captures the raw
/// `diskutil` plists the scanner decides from, so a missed or unmountable
/// card can be replayed from the report alone. Generation never throws —
/// a report about a failure must not itself fail; sections that cannot be
/// gathered say so inline instead.
public struct DiagnosticsReporter: Sendable {
    private let runner: any ProcessRunning
    private let mountTable: any MountTableReading

    public init(runner: any ProcessRunning, mountTable: any MountTableReading = KernelMountTable()) {
        self.runner = runner
        self.mountTable = mountTable
    }

    /// "lifsaver-report-20260717-1432.json" — sortable, filesystem-safe.
    public static func suggestedFilename(for date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return "lifsaver-report-\(formatter.string(from: date)).json"
    }

    /// `userNote` is the reporter's own description of what went wrong;
    /// `appEvents` are the app's recent scan/mount outcomes; `liveLog` is the
    /// console output recorded live during those scans and mount attempts.
    public func generate(
        userNote: String = "", appEvents: [String] = [], liveLog: [String] = []
    ) async -> DiagnosticReport {
        let note = userNote.trimmingCharacters(in: .whitespacesAndNewlines)
        let (mountEntries, mountError) = mountTableDump()
        // One listing serves both the raw dump and the per-disk enumeration — a
        // second spawn could disagree with the first mid-report, which is
        // exactly the inconsistency a diagnostic report exists to rule out.
        let listing = await rawCommand("diskutil", ["list", "-plist"])

        return DiagnosticReport(
            meta: meta(),
            userNote: note.isEmpty ? nil : note,
            appEvents: appEvents,
            liveLog: liveLog,
            scanTrace: await scanTrace(),
            mountTable: mountEntries,
            mountTableError: mountError,
            fsckProcesses: await fsckDump(),
            diskutilList: plistAsJSON(listing),
            diskInfo: await diskInfoDump(fromListing: listing)
        )
    }

    private func meta() -> DiagnosticReport.Meta {
        DiagnosticReport.Meta(
            generated: ISO8601DateFormatter().string(from: Date()),
            version: lifsaverVersion,
            macOS: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: buildArchitecture,
            privacyNote: "Contains disk layout, volume names, and mount paths — "
                + "no file contents. Review it before sharing."
        )
    }

    /// Re-runs the scanner with verbose diagnostics captured, then annotates
    /// each target with its filesystem type and fsck state.
    private func scanTrace() async -> DiagnosticReport.ScanTrace {
        let captured = OSAllocatedUnfairLock(initialState: [String]())
        let console = Console(
            out: { line in captured.withLock { $0.append(line) } },
            err: { line in captured.withLock { $0.append(line) } }
        )
        let scanner = DiskScanner(runner: runner, mountTable: mountTable, console: console, verbose: true)

        var targets: [DiagnosticReport.Target] = []
        var scanError: String?
        do {
            for devId in try await scanner.scanTargets() {
                targets.append(
                    DiagnosticReport.Target(
                        device: devId,
                        fsType: await scanner.partitionFSType(devId),
                        fsckActive: await scanner.isFsckActive(devId)
                    ))
            }
        } catch {
            scanError = "scan failed: \(error)"
        }
        return DiagnosticReport.ScanTrace(
            consoleOutput: captured.withLock { $0 }, targets: targets, error: scanError)
    }

    /// Returns the mount table, or an empty list plus an `unavailable:` error
    /// string when it cannot be read.
    private func mountTableDump() -> ([DiagnosticReport.MountTableEntry], String?) {
        do {
            let entries = try mountTable.entries()
            return (entries.map { .init(device: $0.device, mountPoint: $0.mountPoint) }, nil)
        } catch {
            return ([], "unavailable: \(error)")
        }
    }

    private func fsckDump() async -> [String] {
        // pgrep exits 1 when nothing matches — not an error.
        let listing = await rawCommand("pgrep", ["-fl", "fsck"])
        return listing.split(separator: "\n").map(String.init)
    }

    /// The externality signals (`Internal`, `RemovableMediaOrExternalDevice`)
    /// exist only in per-disk `info` output, so dump it for every whole disk
    /// named in the already-captured listing.
    private func diskInfoDump(fromListing listing: String) async -> [DiagnosticReport.DiskInfo] {
        guard
            let plist = try? PropertyListSerialization.propertyList(from: Data(listing.utf8), format: nil),
            let data = plist as? [String: Any]
        else {
            return [
                DiagnosticReport.DiskInfo(
                    device: "", info: .string("unavailable: could not enumerate disks"))
            ]
        }

        let disks = (data["AllDisksAndPartitions"] as? [[String: Any]] ?? [])
            .compactMap { $0["DeviceIdentifier"] as? String }

        var infos: [DiagnosticReport.DiskInfo] = []
        for disk in disks {
            infos.append(
                .init(device: disk, info: plistAsJSON(await rawCommand("diskutil", ["info", "-plist", disk]))))
        }
        return infos
    }

    private func rawCommand(_ executable: String, _ arguments: [String]) async -> String {
        do {
            let result = try await runner.run(executable, arguments, timeout: queryTimeout)
            return result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return "unavailable: \(error)"
        }
    }
}
