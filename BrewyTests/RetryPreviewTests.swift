@testable import Brewy
import Foundation
import Testing

@Suite("History retry previews")
@MainActor
struct RetryPreviewTests {
    @Test("Maintenance retries preview the exact options and operands", arguments: [
        (["autoremove"], ["autoremove", "--dry-run"]),
        (["cleanup", "--prune=all", "-s"], ["cleanup", "--prune=all", "-s", "--dry-run"]),
        (["cleanup", "--", "wget"], ["cleanup", "--dry-run", "--", "wget"]),
        (["cleanup", "--", "--dry-run"], ["cleanup", "--dry-run", "--", "--dry-run"]),
        (["cleanup", "--dry-run"], ["cleanup", "--dry-run"])
    ])
    func previewArguments(arguments: [String], expected: [String]) async {
        let entry = entry(arguments)
        let mock = MockCommandRunner()
        let (service, _) = makeService(mock: mock)
        mock.setResult(for: expected, output: "Current preview")

        let result = await service.previewRetry(entry)

        #expect(result.success)
        #expect(result.output == "Current preview")
        #expect(mock.executedCommands == [expected])
        #expect(service.actionHistory.isEmpty)
        #expect(!service.hasQuitBlockingOperation)
    }

    @Test("Each attempt obtains fresh output without executing the retry")
    func freshPreview() async {
        let mock = MockCommandRunner()
        let (service, _) = makeService(mock: mock)
        let entry = entry(["autoremove"])
        mock.setResult(for: ["autoremove", "--dry-run"], output: "First preview")
        let first = await service.previewRetry(entry)
        mock.setResult(for: ["autoremove", "--dry-run"], output: "Changed preview")
        let second = await service.previewRetry(entry)

        #expect(first.output == "First preview")
        #expect(second.output == "Changed preview")
        #expect(mock.executedCommands == Array(repeating: ["autoremove", "--dry-run"], count: 2))
        #expect(service.actionHistory.isEmpty)
    }

    @Test("Failed and canceled previews preserve their failure state", arguments: [false, true])
    func failedPreview(cancelled: Bool) async {
        let mock = MockCommandRunner()
        let (service, _) = makeService(mock: mock)
        mock.setResult(
            for: ["autoremove", "--dry-run"],
            result: CommandResult(output: "Preview stopped", success: false, cancelled: cancelled)
        )

        let result = await service.previewRetry(entry(["autoremove"]))

        #expect(!result.success)
        #expect(result.cancelled == cancelled)
        #expect(mock.executedCommands == [["autoremove", "--dry-run"]])
    }

    @Test("Unsupported commands and successful history entries cannot be previewed")
    func unsupportedPreview() async {
        let mock = MockCommandRunner()
        let (service, _) = makeService(mock: mock)
        let unsupported = entry(["install", "wget"])
        #expect(unsupported.retryPreviewArguments == nil)
        let result = await service.previewRetry(unsupported)
        let successful = await service.previewRetry(entry(["autoremove"], status: .success))
        #expect(!result.success)
        #expect(!successful.success)
        #expect(mock.executedCommands.isEmpty)
    }

    private func entry(_ arguments: [String], status: ActionHistoryEntry.Status = .failure) -> ActionHistoryEntry {
        ActionHistoryEntry(
            id: UUID(), command: arguments[0], arguments: arguments,
            packageName: nil, packageSource: nil, status: status, output: "Old failure", timestamp: Date()
        )
    }
}
