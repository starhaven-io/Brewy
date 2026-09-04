import Darwin
import Foundation

extension CommandRunner {
    static func provideStandardInput(_ data: Data?, to pipe: Pipe?) -> String? {
        guard let data, let pipe else { return nil }
        let writer = pipe.fileHandleForWriting
        guard fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
            let message = String(cString: strerror(errno))
            try? writer.close()
            return "Failed to configure command input: \(message)"
        }
        do {
            try writer.write(contentsOf: data)
        } catch {
            try? writer.close()
            return "Failed to provide command input: \(error.localizedDescription)"
        }
        try? writer.close()
        return nil
    }

    static func collectOutput(
        stdoutReader: PipeReader,
        stderrReader: PipeReader,
        deadline: DispatchTime
    ) -> (stdout: String, stderr: String) {
        let stdoutData = stdoutReader.wait { deadline }
        let stderrData = stderrReader.wait { deadline }
        return (
            decodeOutput(stdoutData),
            decodeOutput(stderrData)
        )
    }

    private static func decodeOutput(_ data: Data) -> String {
        var decoder = UTF8StreamDecoder()
        return decoder.decode(data) + decoder.flush()
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

func drainPipesInParallel(
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
