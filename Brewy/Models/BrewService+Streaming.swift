extension BrewService {
    nonisolated static let actionOutputByteLimit = 262_144

    /// Streams command output into a bounded display buffer. The command runner independently
    /// bounds captured output used for error handling and history persistence.
    func runBrewCommandStreaming(_ arguments: [String]) async -> CommandResult {
        let brewPath = CommandRunner.resolvedBrewPath(preferred: customBrewPath)
        let timeout = CommandRunner.timeout(forBrewArguments: arguments)
        let baseline = actionOutput
        let (stream, continuation) = AsyncStream.makeStream(
            of: String.self,
            bufferingPolicy: .bufferingNewest(64)
        )
        // A single consumer applies chunks in arrival order; Task-per-chunk would not
        // guarantee ordering.
        let appender = Task { @MainActor [weak self] in
            for await chunk in stream {
                self?.appendActionOutput(chunk)
            }
        }
        let commandTask = Task { [commandRunner] in
            await commandRunner.runStreaming(arguments, brewPath: brewPath, timeout: timeout) { chunk in
                continuation.yield(chunk)
            }
        }
        actionCommandTask = commandTask
        canCancelCurrentAction = true
        let result = await commandTask.value
        canCancelCurrentAction = false
        actionCommandTask = nil
        continuation.finish()
        await appender.value
        actionOutput = Self.boundedActionOutput(baseline + result.output)
        return result
    }

    func cancelCurrentAction() {
        guard canCancelCurrentAction else { return }
        canCancelCurrentAction = false
        actionCommandTask?.cancel()
    }

    nonisolated static func boundedActionOutput(_ output: String) -> String {
        guard output.utf8.count > actionOutputByteLimit else { return output }
        return "…\n" + UTF8ByteTruncation.suffix(output, maxBytes: actionOutputByteLimit - 4)
    }

    private func appendActionOutput(_ chunk: String) {
        actionOutput += chunk
        if actionOutput.utf8.count > Self.actionOutputByteLimit {
            actionOutput = Self.boundedActionOutput(actionOutput)
        }
    }
}
