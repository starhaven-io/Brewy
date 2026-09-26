extension BrewService {
    // MARK: - Dry-Run Previews

    func previewRetry(_ entry: ActionHistoryEntry) async -> CommandResult {
        guard entry.isRetryable, let arguments = entry.retryPreviewArguments else {
            return CommandResult(output: "This command does not support a retry preview.", success: false)
        }
        return await runBrewCommand(arguments)
    }

    func dryRunAutoremove() async -> CommandResult {
        await runBrewCommand(["autoremove", "--dry-run"])
    }

    func dryRunCleanup() async -> CommandResult {
        await runBrewCommand(["cleanup", "--prune=all", "-s", "--dry-run"])
    }
}
