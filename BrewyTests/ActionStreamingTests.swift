@testable import Brewy
import Foundation
import Testing

// MARK: - Streaming Mock Runner

/// Streams configured chunks with a delay before each, honoring task cancellation the way
/// the real runner does (cancelled result, no error alert expected).
private final class StreamingMockRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _streamedCommands: [[String]] = []
    private let chunks: [String]
    private let chunkDelay: Duration
    private let finalResult: CommandResult
    /// Held after the first chunk so a test can observe the mid-flight state without
    /// racing the scheduler for a transient window.
    private let gateAfterFirstChunk: ChunkGate?

    var streamedCommands: [[String]] {
        lock.withLock { _streamedCommands }
    }

    init(
        chunks: [String],
        chunkDelay: Duration = .milliseconds(20),
        gateAfterFirstChunk: ChunkGate? = nil,
        finalResult: CommandResult
    ) {
        self.chunks = chunks
        self.chunkDelay = chunkDelay
        self.gateAfterFirstChunk = gateAfterFirstChunk
        self.finalResult = finalResult
    }

    /// Post-action refreshes must decode cleanly so they never set lastError themselves.
    func run(_ arguments: [String], brewPath: String, timeout: Duration) async -> CommandResult {
        switch arguments {
        case ["info", "--installed", "--json=v2"]:
            return CommandResult(output: TestJSON.emptyFormulae, success: true)
        case ["outdated", "--json=v2"]:
            return CommandResult(output: TestJSON.emptyOutdated, success: true)
        case ["tap-info", "--json=v1", "--installed"]:
            return CommandResult(output: TestJSON.emptyTaps, success: true)
        default:
            return finalResult
        }
    }

    func runExecutable(_ executablePath: String, arguments: [String], timeout: Duration) async -> CommandResult {
        finalResult
    }

    func runStreaming(
        _ arguments: [String],
        brewPath: String,
        timeout: Duration,
        onOutput: @escaping @Sendable (String) -> Void
    ) async -> CommandResult {
        lock.withLock { _streamedCommands.append(arguments) }
        for (index, chunk) in chunks.enumerated() {
            do {
                try await Task.sleep(for: chunkDelay)
            } catch {
                return CommandResult(output: "Command was cancelled.", success: false, cancelled: true)
            }
            onOutput(chunk)
            if index == 0 { await gateAfterFirstChunk?.wait() }
        }
        return finalResult
    }
}

// MARK: - Streaming Action Tests

@Suite("BrewService Streaming Actions")
@MainActor
struct ActionStreamingTests {

    @Test("Streamed chunks reach actionOutput while the command runs")
    func chunksReachActionOutputMidFlight() async {
        let gate = ChunkGate()
        let runner = StreamingMockRunner(
            chunks: ["first-chunk\n", "second-chunk\n"],
            gateAfterFirstChunk: gate,
            finalResult: CommandResult(output: "first-chunk\nsecond-chunk\n", success: true)
        )
        let service = BrewService(commandRunner: runner)

        let action = Task { await service.performBrewAction(["upgrade"]) }
        // The mock is held after the first chunk, so this converges instead of racing a
        // transient window, and the second chunk cannot arrive early to spoil the check.
        for _ in 0..<1_000 where !service.actionOutput.contains("first-chunk") {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(service.actionOutput.contains("first-chunk"))
        #expect(!service.actionOutput.contains("second-chunk"))

        await gate.open()
        _ = await action.value

        #expect(service.actionOutput == "first-chunk\nsecond-chunk\n")
    }

    @Test("actionOutput is canonicalized to the final result on completion")
    func outputCanonicalizedOnCompletion() async {
        let mock = MockCommandRunner()
        let (service, _) = makeService(mock: mock)
        setupRefreshMock(mock)
        mock.setResult(for: ["autoremove"], output: "Removed nothing")

        await service.performBrewAction(["autoremove"])

        #expect(service.actionOutput == "Removed nothing")
    }

    @Test("actionOutput remains byte-bounded for multi-byte command output")
    func actionOutputRemainsBounded() async {
        let output = String(repeating: "🍺", count: BrewService.actionOutputByteLimit)
        let runner = StreamingMockRunner(
            chunks: [output],
            finalResult: CommandResult(output: output, success: true)
        )
        let service = BrewService(commandRunner: runner)

        await service.performBrewAction(["upgrade"])

        #expect(service.actionOutput.utf8.count <= BrewService.actionOutputByteLimit)
        #expect(service.actionOutput.hasSuffix("🍺"))
    }

    @Test("cancelCurrentAction stops the command without raising the error alert")
    func cancelSkipsErrorAlert() async {
        let runner = StreamingMockRunner(
            chunks: ["never-finishes"],
            chunkDelay: .seconds(30),
            finalResult: CommandResult(output: "unused", success: true)
        )
        let service = BrewService(commandRunner: runner)

        let action = Task { await service.performBrewAction(["upgrade"]) }
        for _ in 0..<200 where !service.isPerformingAction {
            try? await Task.sleep(for: .milliseconds(5))
        }
        service.cancelCurrentAction()
        _ = await action.value

        #expect(service.lastError == nil)
        #expect(!service.isPerformingAction)
        #expect(service.actionHistory.first?.status == .failure)
        #expect(service.actionHistory.first?.output.contains("cancelled") == true)
    }

    @Test("upgradeSelected skips the cask command after cancellation")
    func upgradeSelectedSkipsCasksAfterCancel() async {
        let runner = StreamingMockRunner(
            chunks: ["upgrading"],
            chunkDelay: .seconds(30),
            finalResult: CommandResult(output: "unused", success: true)
        )
        let service = BrewService(commandRunner: runner)
        let packages = [
            makePackage(name: "wget", source: .formula),
            makePackage(name: "firefox", source: .cask)
        ]

        let action = Task { await service.upgradeSelected(packages: packages) }
        for _ in 0..<200 where !service.isPerformingAction {
            try? await Task.sleep(for: .milliseconds(5))
        }
        service.cancelCurrentAction()
        await action.value

        #expect(runner.streamedCommands == [["upgrade", "--", "wget"]])
        #expect(service.lastError == nil)
    }

    @Test("upgradeAll cancellation does not raise the Mac App Store message")
    func upgradeAllCancelSkipsMasMessage() async {
        let runner = StreamingMockRunner(
            chunks: ["upgrading"],
            chunkDelay: .seconds(30),
            finalResult: CommandResult(output: "unused", success: true)
        )
        let service = BrewService(commandRunner: runner)
        service.outdatedPackages = [makePackage(name: "123456", source: .mas, isOutdated: true)]

        let action = Task { await service.upgradeAll() }
        for _ in 0..<200 where !service.canCancelCurrentAction {
            try? await Task.sleep(for: .milliseconds(5))
        }
        service.cancelCurrentAction()
        await action.value

        #expect(service.lastError == nil)
        #expect(!service.canCancelCurrentAction)
    }
}

/// Blocks a mock mid-stream until the test releases it.
private actor ChunkGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
