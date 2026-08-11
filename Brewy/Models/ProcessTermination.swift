import Darwin
import Foundation
import OSLog

private let logger = Logger(subsystem: "io.linnane.brewy", category: "ProcessTermination")

final class ProcessTermination: @unchecked Sendable {
    typealias SignalFunction = @Sendable (Int32, Int32) -> Int32

    private enum SignalOutcome {
        case delivered
        case gone
        case notPermitted
        case failed(Int32)
    }

    private enum WaitOutcome {
        case finished
        case notPermitted
        case timedOut(lastProbeDenied: Bool)
        case failed(Int32)
    }

    private static let confirmationPeriod: Duration = .seconds(5)
    private static let permissionProbeGracePeriod: Duration = .milliseconds(100)
    private static let pollInterval: useconds_t = 10_000

    private let signalTarget: Int32
    private let gracePeriod: Duration
    private let signalFunction: SignalFunction
    private let completion = DispatchGroup()
    private let lock = NSLock()
    private var started = false
    private var succeeded = false

    init(
        process: Process,
        gracePeriod: Duration,
        signalFunction: @escaping SignalFunction = { Darwin.kill($0, $1) }
    ) {
        self.signalTarget = Self.signalTarget(for: process)
        self.gracePeriod = gracePeriod
        self.signalFunction = signalFunction
    }

    func start() {
        guard beginTermination() else { return }

        switch send(SIGTERM, to: signalTarget) {
        case .delivered:
            startEscalationThread(hadPartialDelivery: false)
        case .gone:
            finish(succeeded: true)
        case .notPermitted:
            guard signalTarget < 0 else {
                finishAfterSignalFailure(SIGTERM, error: EPERM)
                return
            }
            logger.warning("SIGTERM reached only part of process group \(-self.signalTarget); escalating")
            startEscalationThread(hadPartialDelivery: true)
        case let .failed(error):
            finishAfterSignalFailure(SIGTERM, error: error)
        }
    }

    private func beginTermination() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !started else { return false }
        started = true
        completion.enter()
        return true
    }

    private func startEscalationThread(hadPartialDelivery: Bool) {
        let escalationDeadline = ContinuousClock.now.advanced(by: gracePeriod)
        let target = signalTarget
        // A dedicated thread keeps process cleanup independent of dispatch-pool starvation.
        let thread = Thread { [self] in
            waitForGracePeriod(
                until: escalationDeadline,
                target: target,
                hadPartialDelivery: hadPartialDelivery
            )
        }
        thread.name = "Brewy process termination"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    private func waitForGracePeriod(
        until deadline: ContinuousClock.Instant,
        target: Int32,
        hadPartialDelivery: Bool
    ) {
        switch waitForExit(until: deadline, toleratingPermissionDenial: hadPartialDelivery) {
        case .finished:
            finish(succeeded: !hadPartialDelivery)
        case .notPermitted:
            guard target < 0 else {
                finishAfterProbeFailure(error: EPERM)
                return
            }
            logger.warning("Could not verify all members of process group \(-target); honoring remaining grace period")
            switch waitForExit(until: deadline, toleratingPermissionDenial: true) {
            case .finished:
                // Initial partial delivery uses the permission-tolerating outer wait,
                // so reaching this branch proves the original SIGTERM was fully delivered.
                finish(succeeded: true)
            case .notPermitted:
                logger.warning("Could not verify all members of process group \(-target); sending SIGKILL")
                sendKill(to: target, hadPartialDelivery: true)
            case let .timedOut(lastProbeDenied):
                if lastProbeDenied {
                    logger.warning("Could not verify all members of process group \(-target); sending SIGKILL")
                } else {
                    logger.warning("SIGTERM did not stop all processes, sending SIGKILL to target \(target)")
                }
                sendKill(to: target, hadPartialDelivery: lastProbeDenied)
            case let .failed(error):
                finishAfterProbeFailure(error: error)
            }
        case let .failed(error):
            finishAfterProbeFailure(error: error)
        case let .timedOut(lastProbeDenied):
            let hadIncompleteDelivery = hadPartialDelivery || lastProbeDenied
            let scope = hadIncompleteDelivery ? "all signalable processes" : "all processes"
            logger.warning("SIGTERM did not stop \(scope), sending SIGKILL to target \(target)")
            sendKill(to: target, hadPartialDelivery: hadIncompleteDelivery)
        }
    }

    private func sendKill(to target: Int32, hadPartialDelivery: Bool) {
        switch send(SIGKILL, to: target) {
        case .delivered:
            confirmKill(target: target, hadPartialDelivery: hadPartialDelivery)
        case .gone:
            finish(succeeded: !hadPartialDelivery)
        case .notPermitted:
            finishAfterSignalFailure(SIGKILL, error: EPERM)
        case let .failed(error):
            finishAfterSignalFailure(SIGKILL, error: error)
        }
    }

    private func confirmKill(target: Int32, hadPartialDelivery: Bool) {
        let deadline = ContinuousClock.now.advanced(by: Self.confirmationPeriod)
        switch waitForExit(until: deadline) {
        case .finished:
            finish(succeeded: !hadPartialDelivery)
        case .notPermitted:
            finishAfterProbeFailure(error: EPERM)
        case let .failed(error):
            finishAfterProbeFailure(error: error)
        case .timedOut:
            logger.error("Process target \(target) still exists after SIGKILL")
            finish(succeeded: false)
        }
    }

    func wait() -> Bool {
        lock.lock()
        let shouldWait = started
        lock.unlock()
        guard shouldWait else { return true }

        completion.wait()
        lock.lock(); defer { lock.unlock() }
        return succeeded
    }

    private func send(_ signal: Int32, to target: Int32) -> SignalOutcome {
        errno = 0
        guard signalFunction(target, signal) != 0 else { return .delivered }
        switch errno {
        case ESRCH:
            return .gone
        case EPERM:
            return .notPermitted
        default:
            return .failed(errno)
        }
    }

    private func waitForExit(
        until deadline: ContinuousClock.Instant,
        toleratingPermissionDenial: Bool = false
    ) -> WaitOutcome {
        var permissionDeadline: ContinuousClock.Instant?
        while true {
            let now = ContinuousClock.now
            switch send(0, to: signalTarget) {
            case .gone:
                return .finished
            case .notPermitted:
                if toleratingPermissionDenial {
                    guard now < deadline else { return .timedOut(lastProbeDenied: true) }
                    break
                }
                // macOS can return EPERM for a group whose terminated leader is awaiting reap.
                let retryDeadline = now.advanced(by: Self.permissionProbeGracePeriod)
                permissionDeadline = permissionDeadline ?? min(deadline, retryDeadline)
                guard let permissionDeadline, now < permissionDeadline else {
                    return .notPermitted
                }
            case let .failed(error):
                return .failed(error)
            case .delivered:
                permissionDeadline = nil
                guard now < deadline else { return .timedOut(lastProbeDenied: false) }
            }
            usleep(Self.pollInterval)
        }
    }

    private func finishAfterSignalFailure(_ signal: Int32, error: Int32) {
        let target = signalTarget
        logger.error(
            "Could not fully deliver signal \(signal) to target \(target), errno \(error); child processes may remain"
        )
        finish(succeeded: false)
    }

    private func finishAfterProbeFailure(error: Int32) {
        logger.error(
            "Could not verify process target \(self.signalTarget), errno \(error); child processes may remain"
        )
        finish(succeeded: false)
    }

    private func finish(succeeded: Bool) {
        lock.lock()
        self.succeeded = succeeded
        lock.unlock()
        completion.leave()
    }

    private static func signalTarget(for process: Process) -> Int32 {
        let pid = process.processIdentifier
        errno = 0
        let processGroupID = getpgid(pid)
        if processGroupID == pid || (processGroupID == -1 && errno == ESRCH) {
            return -pid
        }
        logger.warning("Process \(pid) is not its group leader; terminating only the direct process")
        return pid
    }
}

/// Thread-safe handle bridging a launched `Process` to a task-cancellation handler,
/// which may fire before the process has even launched.
final class ProcessHandle: @unchecked Sendable {
    struct Interruption: Sendable {
        let cancelled: Bool
        let timedOut: Bool
        let terminationSucceeded: Bool
    }

    private let lock = NSLock()
    private var termination: ProcessTermination?
    private var cancelled = false
    private var timedOut = false
    private var processExited = false
    private var finished = false

    func register(_ process: Process, killGracePeriod: Duration) {
        let termination = ProcessTermination(
            process: process,
            gracePeriod: killGracePeriod
        )
        lock.lock()
        self.termination = termination
        if cancelled || timedOut { termination.start() }
        lock.unlock()
    }

    var wasCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        cancelled = true
        termination?.start()
        lock.unlock()
    }

    func processDidExit() {
        lock.lock()
        processExited = true
        lock.unlock()
    }

    @discardableResult
    func timeOut() -> Bool {
        lock.lock()
        guard !processExited, !finished else {
            lock.unlock()
            return false
        }
        timedOut = true
        termination?.start()
        lock.unlock()
        return true
    }

    var wasInterrupted: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled || timedOut
    }

    func waitForTermination() -> Bool {
        lock.lock()
        let termination = termination
        lock.unlock()
        return termination?.wait() ?? true
    }

    func interruptionAfterWaiting() -> Interruption {
        lock.lock()
        finished = true
        let wasCancelled = cancelled
        let didTimeOut = timedOut
        let termination = termination
        lock.unlock()
        return Interruption(
            cancelled: wasCancelled,
            timedOut: didTimeOut,
            terminationSucceeded: termination?.wait() ?? true
        )
    }
}
