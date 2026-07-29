import Foundation

// MARK: - Locked Data

/// Thread-safe accumulator for data chunks.
final class LockedData: Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var chunks: [Data] = []

    func append(_ data: Data) {
        lock.lock()
        chunks.append(data)
        lock.unlock()
    }

    func combined() -> Data {
        lock.lock()
        var result = Data()
        result.reserveCapacity(chunks.reduce(0) { $0 + $1.count })
        for chunk in chunks { result.append(chunk) }
        lock.unlock()
        return result
    }
}

// MARK: - Pipe Reader

/// Drains a `Pipe` to EOF on a background queue so the subprocess cannot deadlock on a full
/// buffer, optionally forwarding each chunk as decoded text while it arrives.
final class PipeReader: @unchecked Sendable {
    private let pipe: Pipe
    private let onText: (@Sendable (String) -> Void)?
    private let accumulator = LockedData()
    private let semaphore = DispatchSemaphore(value: 0)
    /// Only touched from the single reader queue.
    private var decoder = UTF8StreamDecoder()

    init(pipe: Pipe, onText: (@Sendable (String) -> Void)? = nil) {
        self.pipe = pipe
        self.onText = onText
    }

    func start() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let fileHandle = pipe.fileHandleForReading
            while true {
                let data = fileHandle.availableData
                guard !data.isEmpty else { break }
                accumulator.append(data)
                if let onText {
                    let text = decoder.decode(data)
                    if !text.isEmpty { onText(text) }
                }
            }
            if let onText {
                let remainder = decoder.flush()
                if !remainder.isEmpty { onText(remainder) }
            }
            semaphore.signal()
        }
    }

    func wait(untilRequested deadline: () -> DispatchTime?) -> Data {
        while true {
            if let deadline = deadline() {
                if semaphore.wait(timeout: deadline) == .success {
                    return accumulator.combined()
                }
                try? pipe.fileHandleForReading.close()
                return accumulator.combined()
            }
            if semaphore.wait(timeout: .now() + .milliseconds(100)) == .success {
                return accumulator.combined()
            }
        }
    }
}
