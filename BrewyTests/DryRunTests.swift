@testable import Brewy
import Foundation
import Testing

// MARK: - Dry-Run Tests

@Suite("BrewService Dry-Run")
@MainActor
struct DryRunTests {
    @Test("Confirmation stays bound to the executable and arguments that produced the preview")
    func confirmationUsesPreviewedInstallation() async throws {
        let mock = MockCommandRunner()
        let (service, _) = makeService(mock: mock)
        let link = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: link) }
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/usr/bin/true")
        service.customBrewPath = link.path
        let arguments = ["cleanup", "--prune=all", "-s"]
        let dryRun = arguments + ["--dry-run"]
        mock.setResult(for: dryRun, output: "Would clear cache")
        mock.setResult(for: arguments, output: "Cleaned up")
        let preview = await service.dryRunCleanup()
        #expect(preview.result.success)

        await service.removeOrphans(preview)
        service.customBrewPath = "/usr/bin/false"
        await service.purgeCache(preview)
        service.customBrewPath = link.path
        try FileManager.default.removeItem(at: link)
        await service.purgeCache(preview)
        let unavailable = await service.dryRunCleanup()
        #expect(!unavailable.result.success)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/usr/bin/false")
        await service.purgeCache(preview)
        #expect(mock.executedCommands == [dryRun])
        #expect(service.lastError != nil)

        await service.purgeCache(service.dryRunCleanup())
        #expect(mock.executedCommands == [dryRun, dryRun, arguments])
        #expect(mock.executedExecutables.allSatisfy { $0.path == link.path })
    }

    @Test("dryRunAutoremove calls autoremove --dry-run")
    func dryRunAutoremoveCallsCommand() async {
        let mock = MockCommandRunner()
        let (service, _) = makeService(mock: mock)
        mock.setResult(
            for: ["autoremove", "--dry-run"],
            output: "Would remove: libfoo, libbar"
        )

        let result = await service.dryRunAutoremove().result

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

        let result = await service.dryRunCleanup().result

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

        let result = await service.dryRunCleanup().result

        #expect(!result.success)
        #expect(result.output == "Permission denied")
    }

    @Test("removeOrphans calls autoremove and refreshes")
    func removeOrphansCallsAutoremove() async {
        let mock = MockCommandRunner()
        let (service, _) = makeService(mock: mock)
        setupRefreshMock(mock)
        mock.setResult(for: ["autoremove"], output: "Removed orphans")

        mock.setResult(for: ["autoremove", "--dry-run"], output: "Would remove orphans")
        await service.removeOrphans(service.dryRunAutoremove())

        #expect(mock.executedCommands.contains(["autoremove"]))
    }

    @Test("purgeCache calls cleanup with -s flag")
    func purgeCacheCallsCleanup() async {
        let mock = MockCommandRunner()
        let (service, _) = makeService(mock: mock)
        mock.setResult(for: ["cleanup", "--prune=all", "-s"], output: "Purged cache")

        mock.setResult(for: ["cleanup", "--prune=all", "-s", "--dry-run"], output: "Would clear cache")
        await service.purgeCache(service.dryRunCleanup())

        #expect(mock.executedCommands.contains(["cleanup", "--prune=all", "-s"]))
    }

    @Test("cacheSize trims brew cache path and converts KiB to bytes")
    func cacheSizeConvertsKilobytes() async {
        let mock = MockCommandRunner()
        let (service, _) = makeService(mock: mock)
        mock.setResult(for: ["--cache"], output: " /Users/test/Library/Caches/Homebrew \n")
        mock.setResult(for: ["-sk", "--", "/Users/test/Library/Caches/Homebrew"], output: "42\t/Users/test/Library/Caches/Homebrew")

        let size = await service.cacheSize()

        #expect(mock.executedCommands.contains(["--cache"]))
        #expect(mock.executedExecutables.contains { entry in
            entry.path == "/usr/bin/du" && entry.arguments == ["-sk", "--", "/Users/test/Library/Caches/Homebrew"]
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
        mock.setResult(for: ["-sk", "--", "/tmp/homebrew-cache"], output: "not-a-number\t/tmp/homebrew-cache")

        let size = await service.cacheSize()

        #expect(size == 0)
    }
}
