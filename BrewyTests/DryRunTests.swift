@testable import Brewy
import Testing

// MARK: - Dry-Run Tests

@Suite("BrewService Dry-Run")
@MainActor
struct DryRunTests {

    @Test("dryRunAutoremove calls autoremove --dry-run")
    func dryRunAutoremoveCallsCommand() async {
        let mock = MockCommandRunner()
        let (service, _) = makeService(mock: mock)
        mock.setResult(
            for: ["autoremove", "--dry-run"],
            output: "Would remove: libfoo, libbar"
        )

        let result = await service.dryRunAutoremove()

        #expect(mock.executedCommands.contains(["autoremove", "--dry-run"]))
        #expect(result.success)
        #expect(result.output.contains("libfoo"))
    }

    @Test("dryRunCleanup calls cleanup --dry-run")
    func dryRunCleanupCallsCommand() async {
        let mock = MockCommandRunner()
        let (service, _) = makeService(mock: mock)
        mock.setResult(
            for: ["cleanup", "--prune=all", "-s", "--dry-run"],
            output: "Would remove: /path/to/old-1.0.tar.gz"
        )

        let result = await service.dryRunCleanup()

        #expect(mock.executedCommands.contains(["cleanup", "--prune=all", "-s", "--dry-run"]))
        #expect(result.success)
        #expect(result.output.contains("old-1.0"))
    }

    @Test("dryRunCleanup preserves failure result")
    func dryRunCleanupPreservesFailure() async {
        let mock = MockCommandRunner()
        let (service, _) = makeService(mock: mock)
        mock.setResult(
            for: ["cleanup", "--prune=all", "-s", "--dry-run"],
            output: "Permission denied",
            success: false
        )

        let result = await service.dryRunCleanup()

        #expect(!result.success)
        #expect(result.output == "Permission denied")
    }
}
