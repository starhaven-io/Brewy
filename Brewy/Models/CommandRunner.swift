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

    init(output: String, success: Bool, cancelled: Bool = false) {
        self.output = output
        self.success = success
        self.cancelled = cancelled
    }
}

// MARK: - Thread-safe Value Containers

private final class LockedFlag: Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var value = false

    func set() { lock.lock(); value = true; lock.unlock() }

    var isSet: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

/// Thread-safe handle bridging a launched `Process` to a task-cancellation handler,
/// which may fire before the process has even launched.
private final class ProcessHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var signalTarget: Int32?
    private var cancelled = false

    /// Registers the launched process; returns false when cancellation already
    /// happened, in which case the caller must tear the process down itself.
    func register(_ process: Process) -> Bool {
        let signalTarget = CommandRunner.signalTarget(for: process)
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { return false }
        self.process = process
        self.signalTarget = signalTarget
        return true
    }

    var wasCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel(killGracePeriod: Duration) {
        lock.lock()
        cancelled = true
        let running = process
        let target = signalTarget
        lock.unlock()
        guard let running, let target else { return }
        CommandRunner.terminateThenKill(running, signalTarget: target, after: killGracePeriod)
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
            handle.cancel(killGracePeriod: killGracePeriod)
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

    // MARK: - Environment

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
            return CommandResult(output: "Command was cancelled.", success: false, cancelled: true)
        }
        let (process, stdoutPipe, stderrPipe) = configuredProcess(for: execution)

        do {
            try process.run()
        } catch {
            logger.error("Failed to launch process: \(error.localizedDescription)")
            return CommandResult(
                output: "Failed to run \(execution.commandDescription): \(error.localizedDescription)",
                success: false
            )
        }

        if !handle.register(process) {
            // Cancellation raced the launch; the handler never saw the process, so tear it down here.
            terminateThenKill(process, after: killGracePeriod)
        }

        let (stdoutData, stderrData) = drainPipesInParallel(stdout: stdoutPipe, stderr: stderrPipe, onOutput: onOutput)
        let (timedOut, timeoutWork) = scheduleTimeout(
            for: process,
            after: execution.timeout,
            commandDescription: execution.commandDescription
        )

        process.waitUntilExit()
        // Process finished; cancel the pending timeout so it can't fire later.
        timeoutWork.cancel()
        var drainDeadline: DispatchTime?
        let requestedDrainDeadline = {
            if drainDeadline == nil, handle.wasCancelled || timedOut.isSet {
                drainDeadline = DispatchTime.now() + dispatchInterval(from: pipeDrainGracePeriod)
            }
            return drainDeadline
        }
        let out = stdoutData.wait(untilRequested: requestedDrainDeadline)
        let err = stderrData.wait(untilRequested: requestedDrainDeadline)
        let stdout = String(data: out, encoding: .utf8) ?? ""
        let stderr = String(data: err, encoding: .utf8) ?? ""

        if handle.wasCancelled {
            return CommandResult(
                output: cancelledOutput(stdout: stdout, stderr: stderr),
                success: false,
                cancelled: true
            )
        }
        if timedOut.isSet {
            return CommandResult(
                output: timeoutOutput(stdout: stdout, stderr: stderr, timeout: execution.timeout),
                success: false
            )
        }
        return CommandResult(
            output: commandOutput(stdout: stdout, stderr: stderr, terminationStatus: process.terminationStatus),
            success: process.terminationStatus == 0
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

    /// Signals the process group when Foundation launched an isolated group, falling back to
    /// the direct process otherwise.
    static func terminateThenKill(_ process: Process, after grace: Duration) {
        terminateThenKill(process, signalTarget: signalTarget(for: process), after: grace)
    }

    fileprivate static func signalTarget(for process: Process) -> Int32 {
        let pid = process.processIdentifier
        errno = 0
        let processGroupID = getpgid(pid)
        if processGroupID == pid || (processGroupID == -1 && errno == ESRCH) {
            return -pid
        }
        logger.warning("Process \(pid) is not its group leader; terminating only the direct process")
        return pid
    }

    fileprivate static func terminateThenKill(
        _ process: Process,
        signalTarget: Int32,
        after grace: Duration
    ) {
        if signalTarget < 0 {
            errno = 0
            guard kill(signalTarget, SIGTERM) == 0 || errno == EPERM else { return }
        } else {
            guard process.isRunning else { return }
            kill(signalTarget, SIGTERM)
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + dispatchInterval(from: grace)) { [weak process] in
            if signalTarget < 0 {
                errno = 0
                guard kill(signalTarget, 0) == 0 || errno == EPERM else { return }
            } else {
                guard let process, process.isRunning else { return }
            }
            logger.warning("SIGTERM did not stop all processes, sending SIGKILL to target \(signalTarget)")
            kill(signalTarget, SIGKILL)
        }
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

    private static func timeoutOutput(stdout: String, stderr: String, timeout: Duration) -> String {
        let partialOutput = combinedStreams(stdout: stdout, stderr: stderr)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !partialOutput.isEmpty else {
            return "Command timed out after \(timeout)."
        }
        return "Command timed out after \(timeout).\n\(partialOutput)"
    }

    private static func cancelledOutput(stdout: String, stderr: String) -> String {
        let partialOutput = combinedStreams(stdout: stdout, stderr: stderr)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !partialOutput.isEmpty else {
            return "Command was cancelled."
        }
        return "Command was cancelled.\n\(partialOutput)"
    }

    private static func drainPipesInParallel(
        stdout: Pipe,
        stderr: Pipe,
        onOutput: (@Sendable (String) -> Void)?
    ) -> (stdout: PipeReader, stderr: PipeReader) {
        let stdoutReader = PipeReader(pipe: stdout, onText: onOutput)
        let stderrReader = PipeReader(pipe: stderr, onText: onOutput)
        stdoutReader.start()
        stderrReader.start()
        return (stdoutReader, stderrReader)
    }

    private static func scheduleTimeout(
        for process: Process,
        after timeout: Duration,
        commandDescription: String
    ) -> (flag: LockedFlag, work: DispatchWorkItem) {
        let timedOut = LockedFlag()
        let timeoutWork = DispatchWorkItem { [weak process] in
            guard let process, process.isRunning else { return }
            logger.warning("Timeout exceeded, sending SIGTERM: \(commandDescription)")
            timedOut.set()
            terminateThenKill(process, after: killGracePeriod)
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + dispatchInterval(from: timeout),
            execute: timeoutWork
        )
        return (timedOut, timeoutWork)
    }
}
