@testable import Brewy
import Darwin
import Foundation
import Testing

private let incompleteTerminationWarning = "Some child processes may still be running."

@Suite("CommandRunner Process Groups", .serialized)
struct CommandRunnerProcessGroupTests {

    @Test("Timeout waits for a SIGTERM-ignoring descendant")
    func timeoutWaitsForProcessGroup() async throws {
        let pidURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("brewy-timeout-descendant-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidURL) }
        let script = """
        (trap "" TERM HUP; exec </dev/null >/dev/null 2>&1; sleep 30) &
        child=$!
        printf "%s" "$child" > "$1"
        wait
        """
        let task = Task {
            await CommandRunner.runExecutable(
                "/bin/sh",
                arguments: ["-c", script, "brewy-timeout-test", pidURL.path],
                timeout: .seconds(3)
            )
        }
        defer { task.cancel() }

        let descendantPID = try #require(await waitForPIDs(at: pidURL, count: 1).first)
        defer { kill(descendantPID, SIGKILL) }
        #expect(kill(descendantPID, 0) == 0)

        let result = await task.value

        #expect(!result.success)
        #expect(result.output.contains("timed out"))
        #expect(!result.output.contains(incompleteTerminationWarning))
        #expect(kill(descendantPID, 0) == -1)
    }
}

extension CommandRunnerProcessGroupTests {
    @Test("Process exit suppresses timeout without suppressing late cancellation")
    func processExitSuppressesOnlyTimeout() {
        let handle = ProcessHandle()

        handle.processDidExit()

        #expect(!handle.timeOut())
        #expect(!handle.wasInterrupted)

        handle.cancel()
        let interruption = handle.interruptionAfterWaiting()
        #expect(interruption.cancelled)
        #expect(!interruption.timedOut)
    }

    @Test("Partial group permission failure still reaches SIGKILL promptly")
    func partialPermissionFailureEscalatesPromptly() throws {
        try withSleepProcess { process, processID in
            let signals = LockedSignalCalls()
            let termination = ProcessTermination(
                process: process,
                gracePeriod: .milliseconds(50),
                signalFunction: { target, signal in
                    signals.append(target: target, signal: signal)
                    errno = EPERM
                    return -1
                }
            )

            let start = ContinuousClock.now
            termination.start()
            let succeeded = termination.wait()
            let elapsed = ContinuousClock.now - start

            #expect(!succeeded)
            #expect(elapsed >= .milliseconds(50))
            #expect(elapsed < .seconds(1))
            let calls = signals.values
            #expect(calls.first == SignalCall(target: -processID, signal: SIGTERM))
            #expect(calls.last == SignalCall(target: -processID, signal: SIGKILL))
            #expect(calls.dropFirst().dropLast().allSatisfy {
                $0 == SignalCall(target: -processID, signal: 0)
            })
        }
    }

    @Test("Partial group permission failure exits early once the group is gone")
    func partialPermissionFailureExitsWhenGroupIsGone() throws {
        try withSleepProcess { process, processID in
            let signals = LockedSignalCalls()
            let termination = ProcessTermination(
                process: process,
                gracePeriod: .seconds(1),
                signalFunction: { target, signal in
                    signals.append(target: target, signal: signal)
                    errno = signal == SIGTERM ? EPERM : ESRCH
                    return -1
                }
            )

            let start = ContinuousClock.now
            termination.start()
            let succeeded = termination.wait()
            let elapsed = ContinuousClock.now - start

            #expect(!succeeded)
            #expect(elapsed < .milliseconds(500))
            #expect(signals.values == [
                SignalCall(target: -processID, signal: SIGTERM),
                SignalCall(target: -processID, signal: 0)
            ])
        }
    }

    @Test("Persistently denied group liveness probe reports incomplete teardown")
    func persistentlyDeniedProbeReportsIncompleteTeardown() throws {
        try withSleepProcess { process, processID in
            let signals = LockedSignalCalls()
            let termination = ProcessTermination(
                process: process,
                gracePeriod: .milliseconds(200),
                signalFunction: { target, signal in
                    signals.append(target: target, signal: signal)
                    guard signal != SIGTERM else { return 0 }
                    errno = EPERM
                    return -1
                }
            )

            let start = ContinuousClock.now
            termination.start()
            let succeeded = termination.wait()
            let elapsed = ContinuousClock.now - start

            #expect(!succeeded)
            #expect(elapsed >= .milliseconds(200))
            #expect(elapsed < .seconds(1))
            let calls = signals.values
            #expect(calls.first == SignalCall(target: -processID, signal: SIGTERM))
            #expect(calls.count >= 3)
            #expect(calls.last == SignalCall(target: -processID, signal: SIGKILL))
            #expect(calls.dropFirst().dropLast().allSatisfy {
                $0 == SignalCall(target: -processID, signal: 0)
            })
        }
    }

    @Test("Denied group probe keeps incomplete status after successful escalation")
    func deniedProbeEscalationRemainsIncomplete() throws {
        try withSleepProcess { process, processID in
            let signals = LockedSignalCalls()
            let termination = ProcessTermination(
                process: process,
                gracePeriod: .milliseconds(200),
                signalFunction: { target, signal in
                    signals.append(target: target, signal: signal)
                    if signal == SIGTERM || signal == SIGKILL { return 0 }
                    errno = signals.values.contains { $0.signal == SIGKILL } ? ESRCH : EPERM
                    return -1
                }
            )

            termination.start()
            let succeeded = termination.wait()

            #expect(!succeeded)
            let calls = signals.values
            #expect(calls.first == SignalCall(target: -processID, signal: SIGTERM))
            #expect(calls.contains(SignalCall(target: -processID, signal: SIGKILL)))
            #expect(calls.last == SignalCall(target: -processID, signal: 0))
        }
    }

    @Test("Transiently denied group probe can resolve after reaping")
    func transientlyDeniedProbeCanFinishCleanly() throws {
        try withSleepProcess { process, processID in
            let signals = LockedSignalCalls()
            let termination = ProcessTermination(
                process: process,
                gracePeriod: .seconds(3),
                signalFunction: { target, signal in
                    let callCount = signals.append(target: target, signal: signal)
                    switch callCount {
                    case 1:
                        return 0
                    case 2:
                        errno = EPERM
                    default:
                        errno = ESRCH
                    }
                    return -1
                }
            )

            termination.start()
            let succeeded = termination.wait()

            #expect(succeeded)
            #expect(signals.values == [
                SignalCall(target: -processID, signal: SIGTERM),
                SignalCall(target: -processID, signal: 0),
                SignalCall(target: -processID, signal: 0)
            ])
        }
    }

    @Test("Delayed reap after denied group probes finishes cleanly within the grace period")
    func delayedReapAfterDeniedProbesFinishesCleanly() throws {
        try withSleepProcess { process, processID in
            let signals = LockedSignalCalls()
            let termination = ProcessTermination(
                process: process,
                gracePeriod: .seconds(5),
                signalFunction: { target, signal in
                    let callCount = signals.append(target: target, signal: signal)
                    guard signal != SIGTERM else { return 0 }
                    errno = callCount < 17 ? EPERM : ESRCH
                    return -1
                }
            )

            termination.start()
            let succeeded = termination.wait()

            #expect(succeeded)
            let calls = signals.values
            #expect(calls.first == SignalCall(target: -processID, signal: SIGTERM))
            #expect(calls.dropFirst().allSatisfy { $0 == SignalCall(target: -processID, signal: 0) })
        }
    }

    @Test("Resolved probe denial allows successful escalation at the grace deadline")
    func resolvedProbeDenialAllowsSuccessfulEscalation() throws {
        try withSleepProcess { process, processID in
            let signals = LockedSignalCalls()
            let termination = ProcessTermination(
                process: process,
                gracePeriod: .seconds(5),
                signalFunction: { target, signal in
                    let callCount = signals.append(target: target, signal: signal)
                    if signal == SIGTERM || signal == SIGKILL { return 0 }
                    if signals.values.contains(where: { $0.signal == SIGKILL }) {
                        errno = ESRCH
                        return -1
                    }
                    if callCount < 17 {
                        errno = EPERM
                        return -1
                    }
                    return 0
                }
            )

            termination.start()
            let succeeded = termination.wait()

            #expect(succeeded)
            let calls = signals.values
            #expect(calls.first == SignalCall(target: -processID, signal: SIGTERM))
            #expect(calls.contains(SignalCall(target: -processID, signal: SIGKILL)))
            #expect(calls.last == SignalCall(target: -processID, signal: 0))
        }
    }
}

extension CommandRunnerProcessGroupTests {
    @Test("Cancellation kills descendants that ignore SIGTERM and hold pipes open")
    func cancellationKillsProcessGroup() async throws {
        let pidURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("brewy-descendant-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidURL) }
        let script = """
        (trap "" TERM HUP; sleep 30) &
        child=$!
        printf "%s" "$child" > "$1"
        wait
        """
        let task = Task {
            await CommandRunner.runExecutable(
                "/bin/sh",
                arguments: ["-c", script, "brewy-cancel-test", pidURL.path]
            )
        }
        defer { task.cancel() }

        let descendantPID = try #require(await waitForPIDs(at: pidURL, count: 1).first)
        defer { kill(descendantPID, SIGKILL) }

        #expect(kill(descendantPID, 0) == 0)
        let cancelStart = ContinuousClock.now
        task.cancel()
        let result = await task.value
        let elapsed = ContinuousClock.now - cancelStart

        for _ in 0..<200 where kill(descendantPID, 0) == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(result.cancelled)
        #expect(!result.output.contains(incompleteTerminationWarning))
        #expect(elapsed < .seconds(10))
        #expect(kill(descendantPID, 0) == -1)
    }

    @Test("Late cancellation waits for a closed-pipe descendant after the leader exits")
    func lateCancellationWaitsForProcessGroup() async throws {
        let pidURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("brewy-closed-pipes-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidURL) }
        let outputGate = BlockingOutputGate()
        let script = """
        (trap "" TERM HUP; exec </dev/null >/dev/null 2>&1; sleep 30) &
        child=$!
        printf "%s %s" "$$" "$child" > "$1"
        printf ready
        exit 0
        """
        let task = Task {
            await CommandRunner.runExecutable(
                "/bin/sh",
                arguments: ["-c", script, "brewy-cancel-test", pidURL.path],
                onOutput: { _ in outputGate.block() }
            )
        }
        defer {
            task.cancel()
            outputGate.open()
        }

        let pids = try await waitForPIDs(at: pidURL, count: 2)
        let leaderPID = try #require(pids.first)
        let descendantPID = try #require(pids.last)
        defer { kill(descendantPID, SIGKILL) }
        for _ in 0..<1_000 where !outputGate.wasReached {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(outputGate.wasReached)

        for _ in 0..<1_000 where kill(leaderPID, 0) == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(kill(leaderPID, 0) == -1)
        #expect(kill(descendantPID, 0) == 0)

        let cancelStart = ContinuousClock.now
        task.cancel()
        outputGate.open()
        let result = await task.value
        let elapsed = ContinuousClock.now - cancelStart

        #expect(result.cancelled)
        #expect(!result.output.contains(incompleteTerminationWarning))
        #expect(elapsed < .seconds(10))
        #expect(kill(descendantPID, 0) == -1)
    }

    @Test("Cancellation still reaches the group after its leader exits")
    func cancellationAfterLeaderExitKillsProcessGroup() async throws {
        let pidURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("brewy-exited-leader-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidURL) }
        let script = """
        (trap "" TERM HUP; sleep 30) &
        child=$!
        printf "%s %s" "$$" "$child" > "$1"
        exit 0
        """
        let task = Task {
            await CommandRunner.runExecutable(
                "/bin/sh",
                arguments: ["-c", script, "brewy-cancel-test", pidURL.path]
            )
        }
        defer { task.cancel() }

        let pids = try await waitForPIDs(at: pidURL, count: 2)
        let leaderPID = try #require(pids.first)
        let descendantPID = try #require(pids.last)
        defer { kill(descendantPID, SIGKILL) }

        for _ in 0..<200 where kill(leaderPID, 0) == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(kill(leaderPID, 0) == -1)
        #expect(kill(descendantPID, 0) == 0)

        let cancelStart = ContinuousClock.now
        task.cancel()
        let result = await task.value
        let elapsed = ContinuousClock.now - cancelStart

        for _ in 0..<200 where kill(descendantPID, 0) == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(result.cancelled)
        #expect(!result.output.contains(incompleteTerminationWarning))
        #expect(elapsed < .seconds(10))
        #expect(kill(descendantPID, 0) == -1)
    }

    private func waitForPIDs(at url: URL, count: Int) async throws -> [Int32] {
        var pids: [Int32] = []
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while ContinuousClock.now < deadline {
            if let contents = try? String(contentsOf: url, encoding: .utf8) {
                pids = contents.split(separator: " ").compactMap { Int32($0) }
                if pids.count == count { break }
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(pids.count == count)
        return pids
    }
}

private final class BlockingOutputGate: @unchecked Sendable {
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var reached = false
    private var opened = false

    var wasReached: Bool {
        lock.withLock { reached }
    }

    func block() {
        let shouldWait = lock.withLock {
            reached = true
            return !opened
        }
        if shouldWait { release.wait() }
    }

    func open() {
        let shouldSignal = lock.withLock {
            guard !opened else { return false }
            opened = true
            return true
        }
        if shouldSignal { release.signal() }
    }
}

private func withSleepProcess(_ body: (Process, Int32) throws -> Void) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sleep")
    process.arguments = ["30"]
    try process.run()
    let processID = process.processIdentifier
    defer {
        kill(-processID, SIGKILL)
        kill(processID, SIGKILL)
        process.waitUntilExit()
    }
    try body(process, processID)
}

private struct SignalCall: Equatable {
    let target: Int32
    let signal: Int32

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.target == rhs.target && lhs.signal == rhs.signal
    }
}

private final class LockedSignalCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [SignalCall] = []

    var values: [SignalCall] {
        lock.withLock { calls }
    }

    @discardableResult
    func append(target: Int32, signal: Int32) -> Int {
        lock.withLock {
            calls.append(SignalCall(target: target, signal: signal))
            return calls.count
        }
    }
}
