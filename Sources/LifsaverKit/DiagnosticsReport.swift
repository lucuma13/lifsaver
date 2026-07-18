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

    public init(runner: any ProcessRunning, mountTable: any MountTableReading = LiveMountTable()) {
        self.runner = runner
        self.mountTable = mountTable
    }

    /// "lifsaver-report-20260717-1432.txt" — sortable, filesystem-safe.
    public static func suggestedFilename(for date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return "lifsaver-report-\(formatter.string(from: date)).txt"
    }

    /// `userNote` is the reporter's own description of what went wrong;
    /// `appEvents` are the menu bar app's recent scan/mount outcomes.
    public func generate(userNote: String = "", appEvents: [String] = []) async -> String {
        let note = userNote.trimmingCharacters(in: .whitespacesAndNewlines)
        var sections: [(String, String)] = [
            ("What happened", note.isEmpty ? "(not provided)" : note)
        ]
        if !appEvents.isEmpty {
            sections.append(("Recent app events", appEvents.joined(separator: "\n")))
        }
        sections.append(("Scan trace", await scanTrace()))
        sections.append(("Mount table", mountTableDump()))
        sections.append(("fsck processes", await fsckDump()))
        sections.append(("diskutil list -plist", await rawCommand("diskutil", ["list", "-plist"])))
        sections.append(("diskutil info -plist, per whole disk", await diskInfoDump()))

        return header() + "\n\n"
            + sections.map { "## \($0.0)\n\n\($0.1)" }.joined(separator: "\n\n") + "\n"
    }

    private func header() -> String {
        """
        # lifsaver diagnostic report

        - generated: \(ISO8601DateFormatter().string(from: Date()))
        - version: \(lifsaverVersion)
        - macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        - architecture: \(buildArchitecture)

        This report contains your disk layout, volume names, and mount paths —
        no file contents. Review it before sharing.
        """
    }

    /// Re-runs the scanner with verbose diagnostics captured, then annotates
    /// each target with its filesystem type and fsck state.
    private func scanTrace() async -> String {
        let captured = OSAllocatedUnfairLock(initialState: [String]())
        let console = Console(
            out: { line in captured.withLock { $0.append(line) } },
            err: { line in captured.withLock { $0.append(line) } }
        )
        let scanner = DiskScanner(runner: runner, mountTable: mountTable, console: console, verbose: true)

        var lines: [String] = []
        do {
            let targets = try await scanner.scanTargets()
            if targets.isEmpty {
                lines.append("targets: (none)")
            }
            for devId in targets {
                let fsType = await scanner.partitionFSType(devId)
                let fsck = await scanner.isFsckActive(devId) ? "fsck running" : "fsck idle"
                lines.append("target: \(devId) (\(fsType.isEmpty ? "unknown fs" : fsType), \(fsck))")
            }
        } catch {
            lines.append("scan failed: \(error)")
        }
        return (captured.withLock { $0 } + lines).joined(separator: "\n")
    }

    private func mountTableDump() -> String {
        do {
            let entries = try mountTable.entries()
            guard !entries.isEmpty else { return "(empty)" }
            return entries.map { "\($0.device) → \($0.mountPoint)" }.joined(separator: "\n")
        } catch {
            return "unavailable: \(error)"
        }
    }

    private func fsckDump() async -> String {
        // pgrep exits 1 when nothing matches — not an error.
        let listing = await rawCommand("pgrep", ["-fl", "fsck"])
        let trimmed = listing.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "(none running)" : trimmed
    }

    /// The externality signals (`Internal`, `RemovableMediaOrExternalDevice`)
    /// exist only in per-disk `info` output, so dump it for every whole disk.
    private func diskInfoDump() async -> String {
        guard
            let result = try? await runner.run("diskutil", ["list", "-plist"], timeout: queryTimeout),
            let plist = try? PropertyListSerialization.propertyList(from: result.stdout, format: nil),
            let data = plist as? [String: Any]
        else { return "unavailable: could not enumerate disks" }

        let disks = (data["AllDisksAndPartitions"] as? [[String: Any]] ?? [])
            .compactMap { $0["DeviceIdentifier"] as? String }
        guard !disks.isEmpty else { return "(no disks)" }

        var chunks: [String] = []
        for disk in disks {
            chunks.append("--- \(disk) ---\n" + (await rawCommand("diskutil", ["info", "-plist", disk])))
        }
        return chunks.joined(separator: "\n")
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
