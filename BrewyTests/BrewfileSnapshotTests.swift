@testable import Brewy
import Foundation
import Testing

@Suite("Brewfile Snapshots")
@MainActor
struct BrewfileSnapshotTests {
    @Test("disk edits and path changes require trust again")
    func diskEditsAndPathChangesRequireTrust() async throws {
        let brewfile = try Self.makeBrewfile(contents: "brew \"wget\"\n")
        let otherBrewfile = try Self.makeBrewfile(contents: "brew \"curl\"\n")
        let mock = MockCommandRunner()
        let (service, _) = makeService(mock: mock)
        service.customBrewfilePath = brewfile.path
        #expect(service.trustBrewfile(at: brewfile))
        try "brew \"curl\"\n".write(to: brewfile, atomically: true, encoding: .utf8)

        await service.refreshBundle()

        #expect(service.bundleCheckStatus == .untrusted)
        #expect(mock.executedCommands.isEmpty)
        service.customBrewfilePath = otherBrewfile.path

        await service.fetchBundleEntries()
        await service.checkBundle()
        await service.refreshBundle()

        #expect(service.brewfileURL?.path == otherBrewfile.path)
        #expect(service.bundleCheckStatus == .untrusted)
        #expect(mock.executedCommands.isEmpty)
    }

    @Test("unchanged trusted bytes are reread and sent exactly")
    func unchangedTrustedBytesAreSentExactly() async throws {
        let approvedBytes = Data("brew \"wget\"\n".utf8)
        let brewfile = try Self.makeBrewfile(contents: "brew \"wget\"\n")
        let mock = MockCommandRunner()
        let (service, _) = makeService(mock: mock)
        service.customBrewfilePath = brewfile.path
        #expect(service.trustBrewfile(at: brewfile))
        service.brewfileSnapshot = nil
        Self.setBundleListResults(mock)
        mock.setResult(
            for: ["bundle", "check", "--verbose", "--file=-"],
            output: "The Brewfile's dependencies are satisfied.\n"
        )

        await service.refreshBundle()

        #expect(service.bundleCheckStatus == .satisfied)
        #expect(mock.standardInputs.count == 5)
        #expect(mock.standardInputs.allSatisfy { $0.data == approvedBytes })
    }

    @Test("changed source cannot recreate a missing trusted snapshot")
    func changedSourceCannotRecreateSnapshot() async throws {
        let brewfile = try Self.makeBrewfile(contents: "brew \"wget\"\n")
        let mock = MockCommandRunner()
        let (service, _) = makeService(mock: mock)
        service.customBrewfilePath = brewfile.path
        #expect(service.trustBrewfile(at: brewfile))
        service.brewfileSnapshot = nil
        try "brew \"curl\"\n".write(to: brewfile, atomically: true, encoding: .utf8)

        await service.refreshBundle()

        #expect(service.bundleCheckStatus == .untrusted)
        #expect(mock.executedCommands.isEmpty)
    }

    @Test("trust follows symbolic links but rejects directories and oversized files")
    func trustAcceptsLinksToRegularFiles() throws {
        let target = try Self.makeBrewfile(contents: "brew \"wget\"\n")
        let symlink = target.deletingLastPathComponent().appendingPathComponent("LinkedBrewfile")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)
        let directory = target.deletingLastPathComponent()
        let oversized = directory.appendingPathComponent("OversizedBrewfile")
        try Data(repeating: 0x41, count: BrewfileSnapshot.maximumByteCount + 1).write(to: oversized)
        let (service, _) = makeService(mock: MockCommandRunner())

        #expect(service.trustBrewfile(at: symlink))
        #expect(service.brewfileSnapshot?.sourcePath == symlink.standardizedFileURL.path)
        #expect(service.brewfileSnapshot?.data == Data("brew \"wget\"\n".utf8))
        #expect(!service.trustBrewfile(at: directory))
        #expect(!service.trustBrewfile(at: oversized))
    }

    @Test("retargeting a trusted symbolic link requires trust again")
    func retargetedLinkRequiresTrust() async throws {
        let firstTarget = try Self.makeBrewfile(contents: "brew \"wget\"\n")
        let secondTarget = try Self.makeBrewfile(contents: "brew \"curl\"\n")
        let symlink = firstTarget.deletingLastPathComponent().appendingPathComponent("LinkedBrewfile")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: firstTarget)
        let mock = MockCommandRunner()
        let (service, _) = makeService(mock: mock)
        service.customBrewfilePath = symlink.path
        #expect(service.trustBrewfile(at: symlink))
        try FileManager.default.removeItem(at: symlink)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: secondTarget)

        await service.refreshBundle()

        #expect(service.bundleCheckStatus == .untrusted)
        #expect(mock.executedCommands.isEmpty)
    }

    private static func setBundleListResults(_ mock: MockCommandRunner) {
        mock.setResult(for: ["bundle", "list", "--formula", "--file=-"], output: "wget\ncurl\n")
        mock.setResult(for: ["bundle", "list", "--cask", "--file=-"], output: "firefox\n")
        mock.setResult(for: ["bundle", "list", "--tap", "--file=-"], output: "homebrew/core\n")
        mock.setResult(for: ["bundle", "list", "--mas", "--file=-"], output: "Xcode\n")
    }

    private static func makeBrewfile(contents: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrewySnapshotTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let brewfile = directory.appendingPathComponent("Brewfile")
        try contents.write(to: brewfile, atomically: true, encoding: .utf8)
        return brewfile
    }
}
