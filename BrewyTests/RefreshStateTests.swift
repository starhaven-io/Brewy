@testable import Brewy
import Foundation
import Observation
import Testing

@Suite("Refresh state and observation")
@MainActor
struct RefreshStateTests {
    @Test("Same-ID package metadata updates notify installed and derived observers")
    func packageMetadataNotifies() {
        let service = BrewService(commandRunner: MockCommandRunner())
        service.installedFormulae = [makePackage(name: "wget", dependencies: ["openssl"])]
        let installed = LockedChunks()
        let derived = LockedChunks()
        let dependencies = LockedChunks()
        withObservationTracking { _ = service.installedFormulae } onChange: { installed.append("changed") }
        withObservationTracking { _ = service.allInstalled } onChange: { derived.append("changed") }
        withObservationTracking { _ = service.reverseDependencies } onChange: { dependencies.append("changed") }

        service.installedFormulae = [
            makePackage(name: "wget", pinned: true, installedVersion: "2.0", dependencies: ["openssl"])
        ]

        #expect(installed.joined() == "changed")
        #expect(derived.joined() == "changed")
        #expect(dependencies.joined() == "changed")
        #expect(service.installedIDs == ["formula-wget"])
        #expect(service.allInstalled.first?.version == "2.0")
        #expect(service.pinnedPackages.first?.id == "formula-wget")
    }

    @Test("Renaming a group notifies observers without replacing its identity")
    func groupMetadataNotifies() {
        let service = BrewService(commandRunner: MockCommandRunner())
        let group = PackageGroup(name: "Before")
        service.packageGroups = [group]
        let changes = LockedChunks()
        withObservationTracking { _ = service.packageGroups } onChange: { changes.append("changed") }
        service.packageGroups = [PackageGroup(id: group.id, name: "After")]
        #expect(changes.joined() == "changed")
        #expect(service.packageGroups.first?.id == group.id)
    }

    @Test("Detail metadata preserves current installed and pinned state")
    func enrichedDetailUsesCurrentState() {
        let stale = makePackage(name: "wget", installedVersion: "1.0", dependencies: ["openssl"])
        let current = makePackage(name: "wget", pinned: true, installedVersion: "2.0")
        let enriched = current.enriched(with: stale)
        #expect(enriched.version == "2.0")
        #expect(enriched.installedVersion == "2.0")
        #expect(enriched.pinned)
        #expect(enriched.dependencies == ["openssl"])
        #expect(current.enriched(with: makePackage(name: "Other", source: .mas)) == current)
    }

    @Test("A replacement untrusted Brewfile invalidates a pending list")
    func replacementBrewfileInvalidatesPendingList() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("Original")
        let replacement = directory.appendingPathComponent("Replacement")
        try Data("brew \"wget\"\n".utf8).write(to: original)
        try Data("brew \"curl\"\n".utf8).write(to: replacement)
        let mock = MockCommandRunner()
        let service = BrewService(commandRunner: mock)
        service.customBrewfilePath = original.path
        #expect(service.trustBrewfile(at: original))
        let firstCommand = ["bundle", "list", "--formula", "--file=-"]
        mock.setResult(for: firstCommand, output: "wget")
        mock.setDelay(for: firstCommand, duration: .milliseconds(100))
        let oldRefresh = Task { await service.refreshBundle() }
        while !mock.executedCommands.contains(firstCommand) { await Task.yield() }
        service.customBrewfilePath = replacement.path
        await service.refreshBundle()
        await oldRefresh.value
        #expect(service.brewfileURL == replacement)
        #expect(service.bundleCheckStatus == .untrusted)
        #expect(service.bundleEntries.isEmpty)
        #expect(!service.isBundleLoading)
        #expect(service.lastError == nil)
        #expect(mock.executedCommands == [firstCommand])
    }

    @Test("Canceled Bundle commands preserve unknown status without an error")
    func canceledBundleDoesNotPublishFailure() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let brewfile = directory.appendingPathComponent("Brewfile")
        try Data().write(to: brewfile)
        let mock = MockCommandRunner()
        let service = BrewService(commandRunner: mock)
        service.customBrewfilePath = brewfile.path
        #expect(service.trustBrewfile(at: brewfile))
        let cancelled = CommandResult(output: "Command was cancelled.", success: false, cancelled: true)
        mock.setResult(for: ["bundle", "list", "--formula", "--file=-"], result: cancelled)
        await service.refreshBundle()
        #expect(service.bundleCheckStatus == .unknown)
        #expect(!service.isBundleLoading)
        #expect(service.lastError == nil)
        mock.setResult(for: ["bundle", "check", "--verbose", "--file=-"], result: cancelled)
        await service.checkBundle()
        #expect(service.bundleCheckStatus == .unknown)
        #expect(service.lastError == nil)
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrewyRefreshTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }
}
