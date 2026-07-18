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
        err: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
    )
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
    private let lines: OSAllocatedUnfairLock<[String]>
    private let capacity: Int
    private let now: @Sendable () -> Date

    public init(capacity: Int = 400, now: @escaping @Sendable () -> Date = { Date() }) {
        self.lines = OSAllocatedUnfairLock(initialState: [])
        self.capacity = capacity
        self.now = now
    }

    /// Records one line, prefixed with a timestamp.
    public func record(_ line: String) {
        append(["\(ISO8601DateFormatter().string(from: now())) \(line)"])
    }

    /// Appends already-formatted lines verbatim — for merging a log captured
    /// elsewhere (the root helper timestamps its own lines).
    public func append(_ newLines: [String]) {
        lines.withLock {
            $0.append(contentsOf: newLines)
            if $0.count > capacity {
                $0.removeFirst($0.count - capacity)
            }
        }
    }

    public func snapshot() -> [String] {
        lines.withLock { $0 }
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
