extension BrewService {
    // MARK: - Dry-Run Previews

    func dryRunAutoremove() async -> CommandResult {
        await runBrewCommand(["autoremove", "--dry-run"])
    }

    func dryRunCleanup() async -> CommandResult {
        await runBrewCommand(["cleanup", "--prune=all", "-s", "--dry-run"])
    }
}
