import AppKit
@testable import Brewy
import Foundation
import Testing

@Suite("Application termination")
@MainActor
struct ApplicationTerminationTests {
    @Test("Idle apps quit without showing an alert")
    func idleQuit() {
        let delegate = BrewyApplicationDelegate(brewService: BrewService(commandRunner: MockCommandRunner()))
        var alerted = false
        delegate.showOperationInProgressAlert = { alerted = true }
        #expect(delegate.applicationShouldTerminate(.shared) == .terminateNow)
        #expect(!alerted)
    }

    @Test("Quit stays blocked until a canceled action actually finishes")
    func canceledActionMustFinish() async throws {
        let runner = PausedCommandRunner()
        let service = BrewService(commandRunner: runner)
        let delegate = BrewyApplicationDelegate(brewService: service)
        var alertCount = 0
        delegate.showOperationInProgressAlert = { alertCount += 1 }
        let arguments = ["install", "wget"]
        let action = Task { await service.performBrewAction(arguments) }
        try await runner.waitForCommands(1)

        #expect(delegate.applicationShouldTerminate(.shared) == .terminateCancel)
        service.cancelCurrentAction()
        #expect(delegate.applicationShouldTerminate(.shared) == .terminateCancel)
        #expect(alertCount == 2)

        await runner.finish(arguments, result: CommandResult(output: "", success: false, cancelled: true))
        _ = await action.value
        #expect(delegate.applicationShouldTerminate(.shared) == .terminateNow)
    }

    @Test("Non-streaming service mutations prevent quitting", arguments: ["start", "stop", "restart", "cleanup"])
    func serviceOperation(verb: String) async throws {
        let runner = PausedCommandRunner()
        let service = BrewService(commandRunner: runner)
        let task = Task {
            switch verb {
            case "start": await service.startService("postgresql@17")
            case "stop": await service.stopService("postgresql@17")
            case "restart": await service.restartService("postgresql@17")
            default: await service.cleanupServices()
            }
        }
        try await runner.waitForCommands(1)
        #expect(!service.isPerformingAction)
        #expect(service.hasQuitBlockingOperation)
        task.cancel()
        #expect(service.hasQuitBlockingOperation)
        let arguments = verb == "cleanup" ? ["services", verb] : ["services", verb, "--", "postgresql@17"]
        await runner.finish(arguments)
        _ = await task.value
        #expect(!service.hasQuitBlockingOperation)
    }

    @Test("Concurrent mutations stay protected until every mutation finishes")
    func concurrentMutations() async throws {
        let runner = PausedCommandRunner()
        let service = BrewService(commandRunner: runner)
        let start = Task { await service.startService("postgresql@17") }
        let cleanup = Task { await service.cleanupServices() }
        let doctor = Task { await service.doctor() }
        try await runner.waitForCommands(3)
        #expect(service.hasQuitBlockingOperation)
        await runner.finish(["services", "start", "--", "postgresql@17"])
        _ = await start.value
        #expect(service.hasQuitBlockingOperation)
        await runner.finish(["services", "cleanup"])
        _ = await cleanup.value
        #expect(!service.hasQuitBlockingOperation)
        await runner.finish(["doctor"])
        _ = await doctor.value
    }

    @Test("Read-only commands allow quitting", arguments: [
        ["info", "--json=v2", "--installed"], ["search", "wget"], ["doctor"], ["audit"],
        ["services", "list", "--json"], ["bundle", "check", "--file=-"]
    ])
    func readOnlyCommand(arguments: [String]) async throws {
        let runner = PausedCommandRunner()
        let service = BrewService(commandRunner: runner)
        let delegate = BrewyApplicationDelegate(brewService: service)
        var alerted = false
        delegate.showOperationInProgressAlert = { alerted = true }
        let task = Task {
            if arguments.first == "bundle" {
                await service.runBrewCommand(arguments, standardInput: Data("brew \"wget\"\n".utf8))
            } else {
                await service.runBrewCommand(arguments)
            }
        }
        try await runner.waitForCommands(1)
        #expect(delegate.applicationShouldTerminate(.shared) == .terminateNow)
        #expect(!alerted)
        await runner.finish(arguments)
        _ = await task.value
    }

    @Test("External read-only commands allow quitting")
    func readOnlyExecutable() async throws {
        let runner = PausedCommandRunner()
        let service = BrewService(commandRunner: runner)
        let arguments = ["--verify", "/Applications/Firefox.app"]
        let task = Task { await service.commandRunner.runExecutable("/usr/bin/codesign", arguments: arguments) }
        try await runner.waitForCommands(1)
        #expect(!service.hasQuitBlockingOperation)
        await runner.finish(arguments)
        _ = await task.value
    }

    @Test("History retries block quit only for mutations", arguments: ["install", "doctor"])
    func retryOperation(command: String) async throws {
        let runner = PausedCommandRunner()
        let service = BrewService(commandRunner: runner)
        let entry = ActionHistoryEntry(
            id: UUID(), command: command, arguments: [command], packageName: nil, packageSource: nil,
            status: .failure, output: "", timestamp: Date()
        )
        let task = Task { await service.retryAction(entry) }
        try await runner.waitForCommands(1)
        #expect(service.isPerformingAction)
        #expect(service.hasQuitBlockingOperation == (command == "install"))
        await runner.finish([command], result: CommandResult(output: "", success: false))
        await task.value
        #expect(!service.hasQuitBlockingOperation)
    }

    @Test("Reading the analytics setting allows quitting")
    func analyticsRead() async throws {
        let runner = PausedCommandRunner()
        let service = BrewService(commandRunner: runner)
        let task = Task { await service.refreshHomebrewAnalyticsStatus() }
        try await runner.waitForCommands(1)
        #expect(service.isUpdatingHomebrewAnalytics)
        #expect(!service.hasQuitBlockingOperation)
        await runner.finish(["analytics", "state"], result: CommandResult(
            output: "InfluxDB analytics are disabled.", success: true
        ))
        await task.value
    }

    @Test("Changing the analytics setting prevents quitting", arguments: [true, false])
    func analyticsMutation(enabled: Bool) async throws {
        let runner = PausedCommandRunner()
        let service = BrewService(commandRunner: runner)
        let task = Task { await service.setHomebrewAnalyticsEnabled(enabled) }
        try await runner.waitForCommands(1)
        #expect(service.hasQuitBlockingOperation)
        await runner.finish(["analytics", enabled ? "on" : "off"])
        try await runner.waitForCommands(1)
        #expect(service.hasQuitBlockingOperation)
        await runner.finish(["analytics", "state"], result: CommandResult(
            output: "InfluxDB analytics are \(enabled ? "enabled" : "disabled").", success: true
        ))
        await task.value
        #expect(!service.hasQuitBlockingOperation)
    }
}

private actor PausedCommandRunner: CommandRunning {
    private var continuations: [[String]: CheckedContinuation<CommandResult, Never>] = [:]

    func run(_ arguments: [String], brewPath: String, timeout: Duration) async -> CommandResult {
        await withCheckedContinuation { continuations[arguments] = $0 }
    }

    func run(
        _ arguments: [String],
        brewPath: String,
        standardInput: Data,
        timeout: Duration
    ) async -> CommandResult {
        await run(arguments, brewPath: brewPath, timeout: timeout)
    }

    func runExecutable(_ executablePath: String, arguments: [String], timeout: Duration) async -> CommandResult {
        await run(arguments, brewPath: executablePath, timeout: timeout)
    }

    func finish(_ arguments: [String], result: CommandResult = CommandResult(output: "", success: true)) {
        continuations.removeValue(forKey: arguments)?.resume(returning: result)
    }

    func waitForCommands(_ count: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while continuations.count < count, ContinuousClock.now < deadline {
            await Task.yield()
        }
        try #require(continuations.count == count)
    }
}
