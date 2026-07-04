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

    @Test("cacheSize trims brew cache path and converts KiB to bytes")
    func cacheSizeConvertsKilobytes() async {
        let mock = MockCommandRunner()
        let (service, _) = makeService(mock: mock)
        mock.setResult(for: ["--cache"], output: " /Users/test/Library/Caches/Homebrew \n")
        mock.setResult(for: ["-sk", "/Users/test/Library/Caches/Homebrew"], output: "42\t/Users/test/Library/Caches/Homebrew")

        let size = await service.cacheSize()

        #expect(mock.executedCommands.contains(["--cache"]))
        #expect(mock.executedExecutables.contains { entry in
            entry.path == "/usr/bin/du" && entry.arguments == ["-sk", "/Users/test/Library/Caches/Homebrew"]
        })
        #expect(size == 42 * 1_024)
    }

    @Test("cacheSize returns zero when brew cache path is empty")
    func cacheSizeEmptyPath() async {
        let mock = MockCommandRunner()
        let (service, _) = makeService(mock: mock)
        mock.setResult(for: ["--cache"], output: "\n")

        let size = await service.cacheSize()

        #expect(size == 0)
        #expect(!mock.executedExecutables.contains { $0.path == "/usr/bin/du" })
    }

    @Test("cacheSize returns zero when du fails or returns malformed output")
    func cacheSizeInvalidDuOutput() async {
        let mock = MockCommandRunner()
        let (service, _) = makeService(mock: mock)
        mock.setResult(for: ["--cache"], output: "/tmp/homebrew-cache")
        mock.setResult(for: ["-sk", "/tmp/homebrew-cache"], output: "not-a-number\t/tmp/homebrew-cache")

        let size = await service.cacheSize()

        #expect(size == 0)
    }
}
