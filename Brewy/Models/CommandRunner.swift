import Darwin
import Foundation
import OSLog

private let logger = Logger(subsystem: "io.linnane.brewy", category: "CommandRunner")

// MARK: - Command Result

struct CommandResult: Sendable {
    let output: String
    let success: Bool
    /// True when the process was terminated because the awaiting task was cancelled,
    /// so callers can skip failure alerts for user-requested cancellation.
    let cancelled: Bool
    /// Raw standard output, kept separate so structured output remains parseable when
    /// a command intentionally exits nonzero or also emits a warning on standard error.
    let standardOutput: String
    let standardError: String
    let exitCode: Int32?

    init(
        output: String,
        success: Bool,
        cancelled: Bool = false,
        standardOutput: String? = nil,
        standardError: String = "",
        exitCode: Int32? = nil
    ) {
        self.output = output
        self.success = success
        self.cancelled = cancelled
        self.standardOutput = standardOutput ?? output
        self.standardError = standardError
        self.exitCode = exitCode
    }
}

// MARK: - Command Running Protocol

protocol CommandRunning: Sendable {
    func run(_ arguments: [String], brewPath: String, timeout: Duration) async -> CommandResult
    func runExecutable(_ executablePath: String, arguments: [String], timeout: Duration) async -> CommandResult
    /// Runs the command, delivering output incrementally as it arrives. `onOutput` may be
    /// called from arbitrary threads; the returned result still carries the full output.
    func runStreaming(
        _ arguments: [String],
        brewPath: String,
        timeout: Duration,
        onOutput: @escaping @Sendable (String) -> Void
    ) async -> CommandResult
}

extension CommandRunning {
    func run(_ arguments: [String], brewPath: String) async -> CommandResult {
        await run(arguments, brewPath: brewPath, timeout: CommandRunner.defaultTimeout)
    }

    func runExecutable(_ executablePath: String, arguments: [String]) async -> CommandResult {
        await runExecutable(executablePath, arguments: arguments, timeout: CommandRunner.defaultTimeout)
    }

    /// Non-streaming fallback so simple runners (test mocks) satisfy the protocol:
    /// the full output arrives as a single chunk on completion.
    func runStreaming(
        _ arguments: [String],
        brewPath: String,
        timeout: Duration,
        onOutput: @escaping @Sendable (String) -> Void
    ) async -> CommandResult {
        let result = await run(arguments, brewPath: brewPath, timeout: timeout)
        onOutput(result.output)
        return result
    }
}

// MARK: - Default Command Runner

struct DefaultCommandRunner: CommandRunning {
    func run(_ arguments: [String], brewPath: String, timeout: Duration) async -> CommandResult {
        await CommandRunner.run(arguments, brewPath: brewPath, timeout: timeout)
    }

    func runExecutable(_ executablePath: String, arguments: [String], timeout: Duration) async -> CommandResult {
        await CommandRunner.runExecutable(executablePath, arguments: arguments, timeout: timeout)
    }

    func runStreaming(
        _ arguments: [String],
        brewPath: String,
        timeout: Duration,
        onOutput: @escaping @Sendable (String) -> Void
    ) async -> CommandResult {
        await CommandRunner.runExecutable(brewPath, arguments: arguments, timeout: timeout, onOutput: onOutput)
    }
}

// MARK: - Command Runner

enum CommandRunner {

    static let defaultTimeout: Duration = .seconds(300)

    /// Mutating commands legitimately run far past `defaultTimeout` (large downloads, source
    /// builds, post-install scripts); SIGKILLing them mid-flight can leave a broken keg.
    static let extendedTimeout: Duration = .seconds(3_600)

    /// Brew verbs that mutate the installation and may run long.
    private static let longRunningVerbs: Set<String> = [
        "install", "uninstall", "reinstall", "upgrade", "fetch",
        "bundle", "update", "cleanup", "autoremove", "tap", "untap"
    ]

    static func timeout(forBrewArguments arguments: [String]) -> Duration {
        guard let verb = arguments.first, longRunningVerbs.contains(verb) else {
            return defaultTimeout
        }
        return extendedTimeout
    }

    static let preventHomebrewAutoUpdateKey = "preventHomebrewAutoUpdate"
    private static let standardBrewPaths = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]

    /// Grace period between SIGTERM and SIGKILL when a process exceeds its timeout.
    private static let killGracePeriod: Duration = .seconds(3)
    private static let pipeDrainGracePeriod: Duration = .seconds(5)

    static func resolvedBrewPath(preferred: String) -> String {
        if FileManager.default.isExecutableFile(atPath: preferred) { return preferred }
        for path in standardBrewPaths where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return preferred
    }

    static func resolvedPrivilegedBrewPath(
        preferred: String,
        standardPaths: [String] = standardBrewPaths
    ) -> String? {
        if FileManager.default.isExecutableFile(atPath: preferred) {
            return standardBrewPath(matching: preferred, standardPaths: standardPaths)
        }
        return standardPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func preventsHomebrewAutoUpdate(userDefaults: UserDefaults = .standard) -> Bool {
        userDefaults.bool(forKey: preventHomebrewAutoUpdateKey)
    }

    static func run(
        _ arguments: [String],
        brewPath: String,
        timeout: Duration = defaultTimeout
    ) async -> CommandResult {
        await runExecutable(brewPath, arguments: arguments, timeout: timeout)
    }

    static func runExecutable(
        _ executablePath: String,
        arguments: [String],
        timeout: Duration = defaultTimeout,
        onOutput: (@Sendable (String) -> Void)? = nil
    ) async -> CommandResult {
        let execName = URL(fileURLWithPath: executablePath).lastPathComponent
        let commandDescription = "\(execName) \(arguments.joined(separator: " "))"
        logger.info("Running: \(commandDescription)")
        let startTime = ContinuousClock.now
        let preventHomebrewAutoUpdate = preventsHomebrewAutoUpdate()

        let execution = ProcessExecution(
            executablePath: executablePath,
            arguments: arguments,
            timeout: timeout,
            commandDescription: commandDescription,
            preventHomebrewAutoUpdate: preventHomebrewAutoUpdate
        )
        let handle = ProcessHandle()
        let result = await withTaskCancellationHandler {
            await Task.detached(priority: .medium) {
                executeProcess(execution, handle: handle, onOutput: onOutput)
            }.value
        } onCancel: {
            logger.info("Task cancelled, terminating: \(commandDescription)")
            handle.cancel()
        }

        let elapsed = ContinuousClock.now - startTime
        if result.cancelled {
            logger.info("\(commandDescription) cancelled after \(elapsed)")
        } else if result.success {
            logger.info("\(commandDescription) completed in \(elapsed)")
        } else {
            logger.warning("\(commandDescription) failed after \(elapsed): \(result.output.prefix(200))")
        }

        return result
    }

    static func resolvedMasPath() -> String {
        let paths = ["/opt/homebrew/bin/mas", "/usr/local/bin/mas"]
        for path in paths where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return paths[0]
    }
}

// MARK: - Environment and Process Execution

extension CommandRunner {

    static func buildEnvironment(
        brewPath: String,
        preventHomebrewAutoUpdate: Bool,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var env = environment
        let brewBin = URL(fileURLWithPath: brewPath).deletingLastPathComponent().path
        let brewPrefix = URL(fileURLWithPath: brewBin).deletingLastPathComponent().path
        let brewSbin = brewPrefix + "/sbin"

        let currentPath = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        var pathComponents = currentPath.components(separatedBy: ":")

        for dir in [brewSbin, brewBin] where !pathComponents.contains(dir) {
            pathComponents.insert(dir, at: 0)
        }

        env["PATH"] = pathComponents.joined(separator: ":")
        if preventHomebrewAutoUpdate {
            env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        }
        return env
    }

    // MARK: - Private

    private static func standardBrewPath(matching path: String, standardPaths: [String]) -> String? {
        let resolvedPath = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return standardPaths.first { standardPath in
            FileManager.default.isExecutableFile(atPath: standardPath)
                && URL(fileURLWithPath: standardPath).resolvingSymlinksInPath().path == resolvedPath
        }
    }

    /// Convert a `Duration` into a `DispatchTimeInterval` that preserves sub-second precision.
    private static func dispatchInterval(from duration: Duration) -> DispatchTimeInterval {
        let components = duration.components
        let totalNanos = components.seconds * 1_000_000_000 + components.attoseconds / 1_000_000_000
        if totalNanos > Int64(Int.max) { return .seconds(Int.max) }
        return .nanoseconds(Int(totalNanos))
    }

    private struct ProcessExecution: Sendable {
        let executablePath: String
        let arguments: [String]
        let timeout: Duration
        let commandDescription: String
        let preventHomebrewAutoUpdate: Bool
    }

    private static func executeProcess(
        _ execution: ProcessExecution,
        handle: ProcessHandle,
        onOutput: (@Sendable (String) -> Void)?
    ) -> CommandResult {
        guard !handle.wasCancelled else {
            return CommandResult(
                output: "Command was cancelled.",
                success: false,
                cancelled: true,
                standardOutput: ""
            )
        }
        let (process, stdoutPipe, stderrPipe) = configuredProcess(for: execution)

        do {
            try process.run()
        } catch {
            logger.error("Failed to launch process: \(error.localizedDescription)")
            let output = "Failed to run \(execution.commandDescription): \(error.localizedDescription)"
            return CommandResult(
                output: output,
                success: false,
                standardOutput: "",
                standardError: output
            )
        }

        handle.register(process, killGracePeriod: killGracePeriod)

        let (stdoutData, stderrData) = drainPipesInParallel(
            stdout: stdoutPipe,
            stderr: stderrPipe,
            commandDescription: execution.commandDescription,
            onOutput: onOutput
        )
        let timeoutWatchdog = scheduleTimeout(
            handle: handle,
            after: execution.timeout,
            commandDescription: execution.commandDescription
        )

        process.waitUntilExit()
        handle.processDidExit()
        timeoutWatchdog.cancel()
        _ = handle.waitForTermination()
        var drainDeadline: DispatchTime?
        let requestedDrainDeadline = {
            if drainDeadline == nil, handle.wasInterrupted {
                drainDeadline = DispatchTime.now() + dispatchInterval(from: pipeDrainGracePeriod)
            }
            return drainDeadline
        }
        let out = stdoutData.wait(untilRequested: requestedDrainDeadline)
        let err = stderrData.wait(untilRequested: requestedDrainDeadline)
        let stdout = String(data: out, encoding: .utf8) ?? ""
        let stderr = String(data: err, encoding: .utf8) ?? ""
        return commandResult(
            process: process,
            execution: execution,
            handle: handle,
            stdout: stdout,
            stderr: stderr
        )
    }

    private static func commandResult(
        process: Process,
        execution: ProcessExecution,
        handle: ProcessHandle,
        stdout: String,
        stderr: String
    ) -> CommandResult {
        let interruption = handle.interruptionAfterWaiting()

        if interruption.cancelled {
            return CommandResult(
                output: cancelledOutput(
                    stdout: stdout,
                    stderr: stderr,
                    terminationSucceeded: interruption.terminationSucceeded
                ),
                success: false,
                cancelled: true,
                standardOutput: stdout,
                standardError: stderr,
                exitCode: process.terminationStatus
            )
        }
        if interruption.timedOut {
            return CommandResult(
                output: timeoutOutput(
                    stdout: stdout,
                    stderr: stderr,
                    timeout: execution.timeout,
                    terminationSucceeded: interruption.terminationSucceeded
                ),
                success: false,
                standardOutput: stdout,
                standardError: stderr,
                exitCode: process.terminationStatus
            )
        }
        return CommandResult(
            output: commandOutput(stdout: stdout, stderr: stderr, terminationStatus: process.terminationStatus),
            success: process.terminationStatus == 0,
            standardOutput: stdout,
            standardError: stderr,
            exitCode: process.terminationStatus
        )
    }

    private static func configuredProcess(for execution: ProcessExecution) -> (Process, Pipe, Pipe) {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: execution.executablePath)
        process.arguments = execution.arguments
        process.environment = buildEnvironment(
            brewPath: execution.executablePath,
            preventHomebrewAutoUpdate: execution.preventHomebrewAutoUpdate
        )
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        return (process, stdoutPipe, stderrPipe)
    }

    private static func commandOutput(stdout: String, stderr: String, terminationStatus: Int32) -> String {
        if terminationStatus == 0 {
            return stdout.isEmpty ? stderr : stdout
        }
        let combined = combinedStreams(stdout: stdout, stderr: stderr)
        return combined.isEmpty ? "Command failed with exit code \(terminationStatus)." : combined
    }

    private static func combinedStreams(stdout: String, stderr: String) -> String {
        switch (stdout.isEmpty, stderr.isEmpty) {
        case (true, true):
            return ""
        case (true, false):
            return stderr
        case (false, true):
            return stdout
        case (false, false):
            let separator = stdout.hasSuffix("\n") || stderr.hasPrefix("\n") ? "" : "\n"
            return stdout + separator + stderr
        }
    }

    private static func timeoutOutput(
        stdout: String,
        stderr: String,
        timeout: Duration,
        terminationSucceeded: Bool
    ) -> String {
        let partialOutput = combinedStreams(stdout: stdout, stderr: stderr)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let message = partialOutput.isEmpty
            ? "Command timed out after \(timeout)."
            : "Command timed out after \(timeout).\n\(partialOutput)"
        return terminationOutput(message, succeeded: terminationSucceeded)
    }

    private static func cancelledOutput(
        stdout: String,
        stderr: String,
        terminationSucceeded: Bool
    ) -> String {
        let partialOutput = combinedStreams(stdout: stdout, stderr: stderr)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let message = partialOutput.isEmpty
            ? "Command was cancelled."
            : "Command was cancelled.\n\(partialOutput)"
        return terminationOutput(message, succeeded: terminationSucceeded)
    }

    static func terminationOutput(_ message: String, succeeded: Bool) -> String {
        guard !succeeded else { return message }
        return "\(message)\nSome child processes may still be running."
    }

    private static func scheduleTimeout(
        handle: ProcessHandle,
        after timeout: Duration,
        commandDescription: String
    ) -> TimeoutWatchdog {
        TimeoutWatchdog(deadline: .now() + dispatchInterval(from: timeout)) {
            guard handle.timeOut() else { return }
            logger.warning("Timeout exceeded, sending SIGTERM: \(commandDescription)")
        }
    }
}

final class TimeoutWatchdog: @unchecked Sendable {
    private let cancellation: DispatchSemaphore
    private let thread: Thread

    init(deadline: DispatchTime, action: @escaping @Sendable () -> Void) {
        let cancellation = DispatchSemaphore(value: 0)
        self.cancellation = cancellation
        self.thread = Thread {
            guard cancellation.wait(timeout: deadline) == .timedOut else { return }
            action()
        }
        thread.name = "Brewy command timeout"
        thread.qualityOfService = .default
        thread.start()
    }

    func cancel() {
        cancellation.signal()
    }
}

private func drainPipesInParallel(
    stdout: Pipe,
    stderr: Pipe,
    commandDescription: String,
    onOutput: (@Sendable (String) -> Void)?
) -> (stdout: PipeReader, stderr: PipeReader) {
    let stdoutReader = PipeReader(
        pipe: stdout,
        label: "\(commandDescription) stdout",
        onText: onOutput
    )
    let stderrReader = PipeReader(
        pipe: stderr,
        label: "\(commandDescription) stderr",
        onText: onOutput
    )
    stdoutReader.start()
    stderrReader.start()
    return (stdoutReader, stderrReader)
}
