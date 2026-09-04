import Foundation
import OSLog

private let logger = Logger(subsystem: "io.linnane.brewy", category: "PipeReader")

// MARK: - Locked Data

/// Thread-safe accumulator for data chunks.
final class LockedData: Sendable {
    private let lock = NSLock()
    private let maximumByteCount: Int
    nonisolated(unsafe) private var contents = Data()
    nonisolated(unsafe) private var wasTruncated = false

    init(maximumByteCount: Int) {
        self.maximumByteCount = max(0, maximumByteCount)
        contents.reserveCapacity(min(self.maximumByteCount, 65_536))
    }

    func append(_ data: Data) {
        lock.lock()
        let remaining = max(0, maximumByteCount - contents.count)
        if remaining > 0 {
            contents.append(data.prefix(remaining))
        }
        if data.count > remaining {
            wasTruncated = true
        }
        lock.unlock()
    }

    func combined() -> Data {
        lock.lock()
        var result = contents
        if wasTruncated {
            let marker = Data("\n… [output truncated]\n".utf8)
            let contentLimit = max(0, maximumByteCount - marker.count)
            result = Data(contents.prefix(contentLimit))
            result.append(marker.prefix(maximumByteCount - result.count))
        }
        lock.unlock()
        return result
    }
}

// MARK: - Pipe Reader

/// Drains a `Pipe` to EOF through `FileHandle`'s dispatch source, optionally forwarding each
/// chunk as decoded text while it arrives.
final class PipeReader: @unchecked Sendable {
    private let fileHandle: FileHandle
    private let label: String
    private let onText: (@Sendable (String) -> Void)?
    private let accumulator: LockedData
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var decoder = UTF8StreamDecoder()
    private var startedAt: ContinuousClock.Instant?
    private var callbackCount = 0
    private var byteCount = 0
    private var isFinished = false

    init(
        pipe: Pipe,
        label: String = "pipe",
        maximumByteCount: Int = CommandRunner.capturedOutputByteLimit,
        onText: (@Sendable (String) -> Void)? = nil
    ) {
        self.fileHandle = pipe.fileHandleForReading
        self.label = label
        self.onText = onText
        self.accumulator = LockedData(maximumByteCount: maximumByteCount)
    }

    func start() {
        let startTime = ContinuousClock.now
        lock.lock()
        guard startedAt == nil else {
            lock.unlock()
            return
        }
        startedAt = startTime
        lock.unlock()

        logger.debug("Started \(self.label, privacy: .private)")
        fileHandle.readabilityHandler = { [weak self] readableHandle in
            self?.consumeAvailableData(from: readableHandle)
        }
    }

    func wait(untilRequested deadline: () -> DispatchTime?) -> Data {
        while true {
            if let deadline = deadline() {
                if semaphore.wait(timeout: deadline) == .success {
                    return accumulator.combined()
                }
                forceClose()
                return accumulator.combined()
            }
            if semaphore.wait(timeout: .now() + .milliseconds(100)) == .success {
                return accumulator.combined()
            }
        }
    }

    private func consumeAvailableData(from readableHandle: FileHandle) {
        let callbackTime = ContinuousClock.now
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }

        let data = readableHandle.availableData
        callbackCount += 1
        guard !data.isEmpty else {
            finishLocked()
            let metrics = metricsLocked(at: callbackTime)
            lock.unlock()
            closeFileHandle()
            logger.debug("EOF \(self.label, privacy: .private): \(metrics.elapsed), \(metrics.bytes) bytes, \(metrics.callbacks) callbacks")
            return
        }

        let isFirstRead = byteCount == 0
        byteCount += data.count
        accumulator.append(data)
        if let onText {
            let text = decoder.decode(data)
            if !text.isEmpty { onText(text) }
        }
        let metrics = metricsLocked(at: callbackTime)
        lock.unlock()

        if isFirstRead {
            logger.debug(
                "First read \(self.label, privacy: .private): \(metrics.elapsed), \(data.count) bytes"
            )
        }
    }

    private func forceClose() {
        let closeTime = ContinuousClock.now
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        finishLocked()
        let metrics = metricsLocked(at: closeTime)
        lock.unlock()

        closeFileHandle()
        logger.warning("Forced close \(self.label, privacy: .private): \(metrics.elapsed), \(metrics.bytes) bytes, \(metrics.callbacks) callbacks")
    }

    private func finishLocked() {
        isFinished = true
        if let onText {
            let remainder = decoder.flush()
            if !remainder.isEmpty { onText(remainder) }
        }
        semaphore.signal()
    }

    private func metricsLocked(
        at time: ContinuousClock.Instant
    ) -> (elapsed: Duration, bytes: Int, callbacks: Int) {
        let elapsed = startedAt.map { time - $0 } ?? .zero
        return (elapsed, byteCount, callbackCount)
    }

    private func closeFileHandle() {
        fileHandle.readabilityHandler = nil
        try? fileHandle.close()
    }
}
