import Foundation

#if DEBUG
extension UITestCommandRunner {
    func maintenancePreview(_ arguments: [String]) -> CommandResult? {
        guard arguments == ["cleanup", "--prune=all", "-s", "--dry-run"]
            || arguments == ["autoremove", "--dry-run"] else { return nil }
        let command = arguments[0]
        if ProcessInfo.processInfo.environment["BREWY_UI_CLEANUP_PREVIEW_FAILURE"] == "1" {
            return CommandResult(output: "Fixture \(command) preview failed", success: false)
        }
        return CommandResult(output: "Fixture \(command) preview", success: true)
    }
}

extension BrewService {
    static func historyFixtures(timestamp: Date) -> [ActionHistoryEntry] {
        [
            ActionHistoryEntry(
                id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
                command: "upgrade", arguments: ["upgrade", "ripgrep"],
                packageName: "ripgrep", packageSource: .formula, status: .failure,
                output: "Error: fixture upgrade failed", timestamp: timestamp
            ),
            ActionHistoryEntry(
                id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
                command: "cleanup", arguments: ["cleanup", "--prune=all", "-s"],
                packageName: nil, packageSource: nil, status: .failure,
                output: "Error: fixture cleanup failed", timestamp: timestamp
            ),
            ActionHistoryEntry(
                id: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
                command: "autoremove", arguments: ["autoremove"],
                packageName: nil, packageSource: nil, status: .failure,
                output: "Error: fixture autoremove failed", timestamp: timestamp
            )
        ]
    }
}
#endif
