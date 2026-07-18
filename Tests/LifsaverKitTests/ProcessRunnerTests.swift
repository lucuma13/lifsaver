import Foundation
import Testing

@testable import LifsaverKit

/// Real-subprocess tests for DefaultProcessRunner — everything else in the
/// suite fakes ProcessRunning, so the genuine launch/drain/timeout paths are
/// exercised here.
@Suite struct DefaultProcessRunnerTests {
    private let runner = DefaultProcessRunner()

    @Test func capturesStdoutAndZeroStatus() async throws {
        let result = try await runner.run("echo", ["hello"], timeout: 10)
        #expect(result.status == 0)
        #expect(result.stdoutText == "hello\n")
        #expect(result.stderr.isEmpty)
    }

    @Test func capturesStderr() async throws {
        let result = try await runner.run("sh", ["-c", "echo oops >&2"], timeout: 10)
        #expect(result.status == 0)
        #expect(result.stderr == "oops\n")
    }

    @Test func nonZeroExitIsNotAnErrorAtThisLevel() async throws {
        let result = try await runner.run("false", [], timeout: 10)
        #expect(result.status != 0)
    }

    @Test func runCheckedThrowsOnNonZeroExit() async {
        await #expect(throws: ProcessRunnerError.self) {
            try await runner.runChecked("false", [], timeout: 10)
        }
    }

    @Test func missingBinaryExitsNonZeroViaEnv() async throws {
        // The runner launches via /usr/bin/env, so a missing executable is a
        // successful launch that exits 127 — not a launchFailed throw.
        let result = try await runner.run("definitely-not-a-real-binary-\(UUID().uuidString)", [], timeout: 10)
        #expect(result.status == 127)
    }

    @Test func outputLargerThanPipeBufferDoesNotDeadlock() async throws {
        // 256 KiB exceeds the 64 KiB pipe buffer — hangs unless the pipes are
        // drained while the child runs.
        let result = try await runner.run("head", ["-c", "262144", "/dev/zero"], timeout: 10)
        #expect(result.status == 0)
        #expect(result.stdout.count == 262_144)
    }

    @Test func slowProcessIsKilledAndReportedAsTimeout() async {
        let start = ContinuousClock.now
        await #expect(throws: ProcessRunnerError.self) {
            try await runner.run("sleep", ["30"], timeout: 0.2)
        }
        // The child must die with the timeout, not run to completion.
        #expect(ContinuousClock.now - start < .seconds(5))
    }
}
