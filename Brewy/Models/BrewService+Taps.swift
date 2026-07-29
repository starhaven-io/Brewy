import Foundation
import OSLog

private let logger = Logger(subsystem: "io.linnane.brewy", category: "BrewService+Taps")

extension BrewService {

    // MARK: - Ensure Taps Loaded

    func ensureTapsLoaded() async {
        guard !tapsLoaded else { return }
        guard let fetchedTaps = await fetchTaps() else {
            tapsLoaded = false
            return
        }
        installedTaps = fetchedTaps
        tapsLoaded = true
        saveToCache()
    }

    // MARK: - Tap Management

    @discardableResult
    func addTap(name: String) async -> CommandResult {
        await performTapAction { await runTapCommand(["tap", name]) }
    }

    @discardableResult
    func removeTap(name: String) async -> CommandResult {
        await performTapAction { await runTapCommand(["untap", name]) }
    }

    @discardableResult
    func migrateTap(from oldName: String, to newName: String) async -> CommandResult {
        await performTapAction {
            logger.info("Migrating tap \(oldName) → \(newName)")
            let untapped = await runTapCommand(["untap", oldName])
            guard untapped.success else { return untapped }
            let tapped = await runTapCommand(["tap", newName])
            if tapped.success {
                // Drop the old tap's cached health only once the new tap is in place; on rollback
                // it stays installed and keeps its status.
                tapHealthStatuses.removeValue(forKey: oldName)
            } else {
                logger.warning("Rollback: re-adding \(oldName) after failure to add \(newName)")
                _ = await runTapCommand(["tap", oldName])
            }
            return tapped
        }
    }

    private func performTapAction(_ action: () async -> CommandResult) async -> CommandResult {
        guard !isPerformingAction else {
            logger.info("Tap action skipped, action already in progress")
            return CommandResult(output: "Another action is already in progress.", success: false)
        }
        isPerformingAction = true
        actionOutput = ""
        lastError = nil
        defer { isPerformingAction = false }
        let result = await action()
        tapsLoaded = false
        await ensureTapsLoaded()
        await refresh()
        return result
    }

    @discardableResult
    private func runTapCommand(_ arguments: [String]) async -> CommandResult {
        if !actionOutput.isEmpty { actionOutput += "\n" }
        let result = await runBrewCommandStreaming(arguments)
        if !result.success, !result.cancelled {
            lastError = .commandFailed(command: arguments.joined(separator: " "), output: result.output)
        }
        recordAction(arguments: arguments, packageName: nil, packageSource: nil, success: result.success, output: result.output)
        return result
    }
}
