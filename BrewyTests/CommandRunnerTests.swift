@testable import Brewy
import Darwin
import Foundation
import Testing

@Suite("CommandResult")
struct CommandResultTests {

    @Test("CommandResult is Sendable and stores output + success")
    func basicFields() {
        let result = CommandResult(output: "hi", success: true)
        #expect(result.output == "hi")
        #expect(result.success)
    }
}

@Suite("MockCommandRunner Behavior")
struct MockCommandRunnerBehaviorTests {

    @Test("Returns configured result for matching arguments")
    func returnsConfiguredResult() async {
        let mock = MockCommandRunner()
        mock.setResult(for: ["install", "wget"], output: "done", success: true)
        let result = await mock.run(["install", "wget"], brewPath: "/bin/true")
        #expect(result.success)
        #expect(result.output == "done")
    }

    @Test("Returns failure fallback for unconfigured arguments")
    func unconfiguredFallsBack() async {
        let mock = MockCommandRunner()
        let result = await mock.run(["never-set"], brewPath: "/bin/true")
        #expect(!result.success)
        #expect(result.output.isEmpty)
    }

    @Test("Records executed commands in order")
    func recordsExecutedCommands() async {
        let mock = MockCommandRunner()
        mock.setResult(for: ["a"], output: "", success: true)
        mock.setResult(for: ["b"], output: "", success: true)
        _ = await mock.run(["a"], brewPath: "/bin/true")
        _ = await mock.run(["b"], brewPath: "/bin/true")
        #expect(mock.executedCommands == [["a"], ["b"]])
    }
}

@Suite("Command Timeout Selection")
struct CommandTimeoutSelectionTests {

    @Test("Mutating verbs get the extended timeout", arguments: [
        ["install", "--", "wget"],
        ["uninstall", "--cask", "--", "firefox"],
        ["reinstall", "--", "wget"],
        ["upgrade"],
        ["upgrade", "--cask", "--", "firefox"],
        ["fetch", "--", "wget"],
        ["bundle", "dump", "--file", "/tmp/Brewfile"],
        ["update"],
        ["cleanup", "--prune=all", "-s"],
        ["autoremove"],
        ["tap", "user/repo"],
        ["untap", "user/repo"]
    ])
    func mutatingVerbsGetExtendedTimeout(arguments: [String]) {
        #expect(CommandRunner.timeout(forBrewArguments: arguments) == CommandRunner.extendedTimeout)
    }

    @Test("Read-only verbs keep the default timeout", arguments: [
        ["info", "--installed", "--json=v2"],
        ["outdated", "--json=v2"],
        ["search", "--formula", "--", "wget"],
        ["doctor"],
        ["services", "list", "--json"],
        ["config"],
        ["tap-info", "--json=v1", "--installed"],
        []
    ])
    func readOnlyVerbsKeepDefaultTimeout(arguments: [String]) {
        #expect(CommandRunner.timeout(forBrewArguments: arguments) == CommandRunner.defaultTimeout)
    }

    @Test("Extended timeout comfortably exceeds the default")
    func extendedExceedsDefault() {
        #expect(CommandRunner.extendedTimeout > CommandRunner.defaultTimeout)
    }
}

@Suite("BrewService Timeout Propagation")
@MainActor
struct BrewServiceTimeoutPropagationTests {

    @Test("Package actions pass the extended timeout")
    func actionUsesExtendedTimeout() async {
        let mock = MockCommandRunner()
        let (service, _) = makeService(mock: mock)
        setupRefreshMock(mock)
        mock.setResult(for: ["install", "--", "wget"], output: "ok")

        await service.install(package: makePackage(name: "wget", source: .formula))

        #expect(mock.recordedTimeout(for: ["install", "--", "wget"]) == CommandRunner.extendedTimeout)
    }

    @Test("Refresh fetches keep the default timeout")
    func fetchesUseDefaultTimeout() async {
        let mock = MockCommandRunner()
        let (service, _) = makeService(mock: mock)
        setupRefreshMock(mock)

        await service.refresh()

        #expect(mock.recordedTimeout(for: ["info", "--installed", "--json=v2"]) == CommandRunner.defaultTimeout)
        #expect(mock.recordedTimeout(for: ["outdated", "--json=v2"]) == CommandRunner.defaultTimeout)
    }
}

// `/Users/runner` is the GitHub Actions runner home; `CI` / `GITHUB_ACTIONS`
// don't reliably reach the test host under `xcodebuild test`.
@Suite(
    "CommandRunner Process Execution",
    .disabled(
        if: FileManager.default.fileExists(atPath: "/Users/runner"),
        "Pipe reads hang on Actions runner images; run locally"
    )
)
struct CommandRunnerProcessTests {

    @Test("runExecutable captures stdout from echo")
    func echoStdout() async {
        let result = await CommandRunner.runExecutable("/bin/echo", arguments: ["hello", "world"])
        #expect(result.success)
        #expect(result.output.contains("hello world"))
    }

    @Test("runExecutable reports failure for nonzero exit")
    func nonzeroExit() async {
        let result = await CommandRunner.runExecutable("/usr/bin/false", arguments: [])
        #expect(!result.success)
    }

    @Test("runExecutable captures stderr when stdout is empty")
    func stderrFallback() async {
        let result = await CommandRunner.runExecutable(
            "/bin/sh",
            arguments: ["-c", "echo error-message >&2; exit 2"]
        )
        #expect(!result.success)
        #expect(result.output.contains("error-message"))
    }

    @Test("runExecutable prefers stdout over stderr when both produced")
    func stdoutWinsOverStderr() async {
        let result = await CommandRunner.runExecutable(
            "/bin/sh",
            arguments: ["-c", "echo stdout-line; echo stderr-line >&2"]
        )
        #expect(result.success)
        #expect(result.output.contains("stdout-line"))
        #expect(!result.output.contains("stderr-line"))
    }

    @Test("runExecutable includes stderr on failure when stdout exists")
    func failureCombinesStdoutAndStderr() async {
        let result = await CommandRunner.runExecutable(
            "/bin/sh",
            arguments: ["-c", "echo stdout-line; echo stderr-line >&2; exit 2"]
        )
        #expect(!result.success)
        #expect(result.output.contains("stdout-line"))
        #expect(result.output.contains("stderr-line"))
    }

    @Test("runExecutable reports the exit code when failure has no output")
    func failureWithNoOutputReportsExitCode() async {
        let result = await CommandRunner.runExecutable(
            "/bin/sh",
            arguments: ["-c", "exit 3"]
        )
        #expect(!result.success)
        #expect(result.output.contains("exit code 3"))
    }

    @Test("runExecutable times out a long-running process")
    func timeoutKillsProcess() async {
        let start = ContinuousClock.now
        let result = await CommandRunner.runExecutable(
            "/bin/sh",
            arguments: ["-c", "sleep 30"],
            timeout: .seconds(1)
        )
        let elapsed = ContinuousClock.now - start
        #expect(!result.success)
        #expect(elapsed < .seconds(15))
    }

    @Test("runExecutable includes partial output on timeout")
    func timeoutIncludesPartialOutput() async {
        let result = await CommandRunner.runExecutable(
            "/bin/sh",
            arguments: ["-c", "echo before-timeout; sleep 30"],
            timeout: .seconds(1)
        )
        #expect(!result.success)
        #expect(result.output.contains("Command timed out"))
        #expect(result.output.contains("before-timeout"))
    }

    @Test("runExecutable handles missing executable gracefully")
    func missingExecutable() async {
        let result = await CommandRunner.runExecutable(
            "/nonexistent/path/to/binary",
            arguments: []
        )
        #expect(!result.success)
        #expect(!result.output.isEmpty)
    }

    @Test("runExecutable drains large stdout without deadlock")
    func largeOutputDrains() async {
        let result = await CommandRunner.runExecutable(
            "/bin/sh",
            arguments: ["-c", "yes output | head -n 10000"]
        )
        #expect(result.success)
        let lineCount = result.output.split(separator: "\n").count
        #expect(lineCount >= 10_000)
    }

    @Test("Task cancellation terminates the child process")
    func cancellationTerminatesProcess() async {
        let task = Task {
            await CommandRunner.runExecutable("/bin/sh", arguments: ["-c", "sleep 30"])
        }
        try? await Task.sleep(for: .milliseconds(300))
        let cancelStart = ContinuousClock.now
        task.cancel()
        let result = await task.value
        let elapsed = ContinuousClock.now - cancelStart

        #expect(!result.success)
        #expect(result.cancelled)
        #expect(result.output.contains("cancelled"))
        #expect(elapsed < .seconds(10))
    }

    @Test("Cancellation before launch skips running the process")
    func preCancelledSkipsLaunch() async {
        let task = Task { () -> CommandResult in
            // Cancelled during this sleep, so the command starts pre-cancelled.
            try? await Task.sleep(for: .seconds(5))
            return await CommandRunner.runExecutable("/bin/echo", arguments: ["never-runs"])
        }
        task.cancel()
        let result = await task.value

        #expect(!result.success)
        #expect(result.cancelled)
        #expect(!result.output.contains("never-runs"))
    }

    @Test("Cancelled result keeps partial output")
    func cancelledResultKeepsPartialOutput() async {
        let chunks = LockedChunks()
        let task = Task {
            await CommandRunner.runExecutable(
                "/bin/sh",
                arguments: ["-c", "echo before-cancel; sleep 30"],
                onOutput: { chunks.append($0) }
            )
        }
        defer { task.cancel() }

        for _ in 0..<1_000 where !chunks.joined().contains("before-cancel") {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(chunks.joined().contains("before-cancel"))

        task.cancel()
        let result = await task.value

        #expect(result.cancelled)
        #expect(result.output.contains("before-cancel"))
    }

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

        for _ in 0..<1_000 where !FileManager.default.fileExists(atPath: pidURL.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let pidText = try String(contentsOf: pidURL, encoding: .utf8)
        let descendantPID = try #require(Int32(pidText))
        defer { kill(descendantPID, SIGKILL) }

        let cancelStart = ContinuousClock.now
        task.cancel()
        let result = await task.value
        let elapsed = ContinuousClock.now - cancelStart

        for _ in 0..<200 where kill(descendantPID, 0) == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(result.cancelled)
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

        for _ in 0..<1_000 where !FileManager.default.fileExists(atPath: pidURL.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let pids = try String(contentsOf: pidURL, encoding: .utf8)
            .split(separator: " ")
            .compactMap { Int32($0) }
        #expect(pids.count == 2)
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
        #expect(elapsed < .seconds(10))
        #expect(kill(descendantPID, 0) == -1)
    }

    @Test("Streaming delivers output and matches the final result")
    func streamingDeliversOutput() async {
        let chunks = LockedChunks()
        let result = await CommandRunner.runExecutable(
            "/bin/sh",
            arguments: ["-c", "printf first; sleep 0.3; printf second"],
            onOutput: { chunks.append($0) }
        )

        #expect(result.success)
        #expect(chunks.joined() == "firstsecond")
        #expect(result.output == "firstsecond")
    }

    @Test("Streaming forwards stderr as it arrives")
    func streamingForwardsStderr() async {
        let chunks = LockedChunks()
        let result = await CommandRunner.runExecutable(
            "/bin/sh",
            arguments: ["-c", "echo err-line >&2; exit 1"],
            onOutput: { chunks.append($0) }
        )

        #expect(!result.success)
        #expect(chunks.joined().contains("err-line"))
    }
}

@Suite("UTF8StreamDecoder")
struct UTF8StreamDecoderTests {

    @Test("ASCII chunks pass straight through")
    func asciiPassesThrough() {
        var decoder = UTF8StreamDecoder()
        #expect(decoder.decode(Data("hello ".utf8)) == "hello ")
        #expect(decoder.decode(Data("world".utf8)) == "world")
        #expect(decoder.flush().isEmpty)
    }

    @Test("Multi-byte scalar split across chunks reassembles")
    func splitScalarReassembles() {
        var decoder = UTF8StreamDecoder()
        let arrow = Data("→".utf8) // 3 bytes: E2 86 92
        var output = decoder.decode(Data("a".utf8) + arrow.prefix(2))
        #expect(output == "a")
        output += decoder.decode(arrow.suffix(1) + Data("b".utf8))
        #expect(output == "a→b")
        #expect(decoder.flush().isEmpty)
    }

    @Test("Four-byte emoji split across chunks reassembles")
    func splitEmojiReassembles() {
        var decoder = UTF8StreamDecoder()
        let emoji = Data("🍺".utf8) // 4 bytes
        var output = decoder.decode(emoji.prefix(1))
        output += decoder.decode(emoji.dropFirst(1).prefix(2))
        output += decoder.decode(emoji.suffix(1))
        #expect(output == "🍺")
    }

    @Test("Flush emits held-back partial bytes as a replacement character")
    func flushEmitsPending() {
        var decoder = UTF8StreamDecoder()
        let arrow = Data("→".utf8)
        #expect(decoder.decode(arrow.prefix(2)).isEmpty)
        // A truncated scalar is one maximal subpart, so it decodes to a single U+FFFD.
        #expect(decoder.flush() == "\u{FFFD}")
    }

    @Test("Invalid lead byte decodes as replacement instead of stalling")
    func invalidLeadByteDecodes() {
        var decoder = UTF8StreamDecoder()
        let output = decoder.decode(Data([0x61, 0xFF]))
        #expect(output == "a\u{FFFD}")
        #expect(decoder.flush().isEmpty)
    }
}
