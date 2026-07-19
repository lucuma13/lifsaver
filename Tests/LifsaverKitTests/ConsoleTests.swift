import Foundation
import Testing

@testable import LifsaverKit

// ===========================================================================
// Live console log
// ===========================================================================

@Suite struct ConsoleLogTests {
    @Test func recordedLinesCarryTimestamps() {
        let log = ConsoleLog(now: { Date(timeIntervalSince1970: 0) })
        log.record("Target: /dev/disk4s1")
        #expect(log.snapshot() == ["1970-01-01T00:00:00Z Target: /dev/disk4s1"])
    }

    @Test func teeConsoleRecordsAndForwardsBothStreams() {
        let log = ConsoleLog(now: { Date(timeIntervalSince1970: 0) })
        let wrapped = CapturedConsole()
        let console = log.console(alsoTo: wrapped.console)

        console.out("attempting mount")
        console.err("mount stderr")

        #expect(wrapped.out == ["attempting mount"])
        #expect(wrapped.err == ["mount stderr"])
        #expect(
            log.snapshot() == [
                "1970-01-01T00:00:00Z attempting mount",
                "1970-01-01T00:00:00Z mount stderr",
            ])
    }

    @Test func oldestLinesRollOffPastCapacity() {
        // The disk watcher rescans on every disk event for as long as the app
        // stays resident; the buffer must stay bounded and keep the newest.
        let log = ConsoleLog(capacity: 3)
        log.append(["1", "2"])
        log.append(["3", "4", "5"])
        #expect(log.snapshot() == ["3", "4", "5"])
    }

    @Test func appendMergesForeignLinesVerbatim() {
        // The root helper's lines arrive already timestamped by its own log;
        // merging must not re-stamp them.
        let log = ConsoleLog()
        log.append(["--- escalated helper (root) ---", "already stamped line"])
        #expect(log.snapshot() == ["--- escalated helper (root) ---", "already stamped line"])
    }
}
