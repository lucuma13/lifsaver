import Foundation
import os

/// Injectable output sink so callers decide where diagnostic text lands: the
/// app routes it to its log, diagnostic reports capture it, and the root
/// helper sends it to stderr. `.standard` mirrors stdout/stderr for tests and
/// bare `swift run` development.
public struct Console: Sendable {
    public var out: @Sendable (String) -> Void
    public var err: @Sendable (String) -> Void

    public init(out: @escaping @Sendable (String) -> Void, err: @escaping @Sendable (String) -> Void) {
        self.out = out
        self.err = err
    }

    public static let standard = Console(
        out: { print($0) },
        err: { writeStandardError($0 + "\n") }
    )
}

/// Serializes writes to real stderr. The helper funnels both console streams
/// here from tasks that can run concurrently, and raw `FileHandle` writes
/// neither lock nor guarantee whole-line atomicity — so interleaved bytes are
/// possible without this. Also uses the throwing overload rather than the
/// deprecated one that raises an Objective-C exception on error.
private let standardErrorQueue = DispatchQueue(label: "app.lifsaver.console.stderr")
private func writeStandardError(_ text: String) {
    standardErrorQueue.sync {
        try? FileHandle.standardError.write(contentsOf: Data(text.utf8))
    }
}

/// Timestamped, capped, thread-safe buffer of live `Console` output, so a
/// diagnostic report can show what actually happened during past scans and
/// mount attempts instead of only a re-scan taken at report time.
///
/// `console(alsoTo:)` builds the tee: every line is recorded here and forwarded
/// to the wrapped console. Oldest lines roll off past `capacity` — the disk
/// watcher rescans on every disk event, and an unbounded buffer would grow for
/// as long as the app stays resident.
public final class ConsoleLog: Sendable {
    /// A recorded line keeps its `Date` rather than a formatted string: the
    /// timestamp is rendered only in `snapshot()`, which almost nothing calls
    /// (lines surface only when a diagnostic report is saved). A `nil` date
    /// marks a line already formatted elsewhere — merged verbatim.
    private struct Entry: Sendable {
        let timestamp: Date?
        let text: String
    }

    private let entries: OSAllocatedUnfairLock<[Entry]>
    private let capacity: Int
    private let now: @Sendable () -> Date

    public init(capacity: Int = 400, now: @escaping @Sendable () -> Date = { Date() }) {
        self.entries = OSAllocatedUnfairLock(initialState: [])
        self.capacity = capacity
        self.now = now
    }

    /// Records one line, stamped with the current time (formatted on read).
    public func record(_ line: String) {
        add([Entry(timestamp: now(), text: line)])
    }

    /// Appends already-formatted lines verbatim — for merging a log captured
    /// elsewhere (the root helper timestamps its own lines).
    public func append(_ newLines: [String]) {
        add(newLines.map { Entry(timestamp: nil, text: $0) })
    }

    private func add(_ newEntries: [Entry]) {
        entries.withLock {
            $0.append(contentsOf: newEntries)
            if $0.count > capacity {
                $0.removeFirst($0.count - capacity)
            }
        }
    }

    public func snapshot() -> [String] {
        entries.withLock { store in
            store.map { entry in
                guard let timestamp = entry.timestamp else { return entry.text }
                return "\(timestamp.formatted(.iso8601)) \(entry.text)"
            }
        }
    }

    /// A console that records every line here and forwards it to `other`.
    public func console(alsoTo other: Console) -> Console {
        Console(
            out: { line in
                self.record(line)
                other.out(line)
            },
            err: { line in
                self.record(line)
                other.err(line)
            }
        )
    }
}
