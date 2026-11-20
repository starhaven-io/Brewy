@testable import Brewy
import Darwin
import Foundation
import Testing

@Suite("Brewfile Snapshots")
@MainActor
struct BrewfileSnapshotTests {
    @Test("A file edited while its review is open needs a fresh review")
    func editingOpenReviewRequiresNewApproval() async throws {
        let url = try Self.makeBrewfile(contents: "brew \"wget\"\n")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let mock = MockCommandRunner()
        let (service, _) = makeService(mock: mock)
        service.customBrewfilePath = url.path
        let first = try BrewfileReview(reading: url)
        #expect(first.contents == "brew \"wget\"\n")
        #expect(!first.showsBytes)
        try Data("brew \"curl\"\n".utf8).write(to: url, options: .atomic)

        #expect(throws: BrewfileSnapshotError.changedSinceReview) { try service.trustReviewedBrewfile(first.snapshot) }
        await service.refreshBundle()
        #expect(mock.executedCommands.isEmpty)
        #expect(service.trustedBrewfileDigest.isEmpty)
        #expect(service.bundleCheckStatus == .untrusted)

        let current = try BrewfileReview(reading: url)
        try service.trustReviewedBrewfile(current.snapshot)
        Self.setBundleListResults(mock)
        await service.refreshBundle()
        #expect(service.trustedBrewfileDigest == current.snapshot.digest)
        #expect(mock.standardInputs.count == 5)
        #expect(mock.standardInputs.allSatisfy { $0.data == Data(current.contents.utf8) })
    }

    @Test("Switching the selected path cannot approve an open review, even for identical bytes")
    func changingSelectionRequiresNewApproval() throws {
        let first = try Self.makeBrewfile(contents: "brew \"wget\"\n")
        let second = try Self.makeBrewfile(contents: "brew \"wget\"\n")
        defer {
            try? FileManager.default.removeItem(at: first.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: second.deletingLastPathComponent())
        }
        let (service, _) = makeService(mock: MockCommandRunner())
        service.customBrewfilePath = first.path
        let review = try BrewfileReview(reading: first)
        service.customBrewfilePath = second.path
        #expect(throws: BrewfileSnapshotError.changedSinceReview) { try service.trustReviewedBrewfile(review.snapshot) }
        #expect(service.trustedBrewfilePath.isEmpty)
    }

    @Test("A review shows file bytes without replacing invalid text or hiding control characters",
          arguments: [([0x61, 0xff, 0x0a] as [UInt8], "61 ff 0a"), ([0x61, 0x00, 0x0a], "61 00 0a")])
    func reviewShowsExactBytes(bytes: [UInt8], expected: String) throws {
        let url = try Self.makeBrewfile(contents: "")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try Data(bytes).write(to: url)
        let review = try BrewfileReview(reading: url)
        #expect(review.showsBytes)
        #expect(review.contents == expected)
        #expect(review.snapshot.data == Data(bytes))
        #expect(review.lineCount == 1)
    }

    @Test("Review counts include blank and unterminated lines", arguments: [
        ("", 0), ("brew \"wget\"", 1), ("brew \"wget\"\n", 1), ("\r\n\r\n", 2), ("\n\nlast", 3)
    ])
    func reviewLineCount(contents: String, expected: Int) throws {
        let url = try Self.makeBrewfile(contents: contents)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let review = try BrewfileReview(reading: url)
        #expect(review.lineCount == expected)
    }

    @Test("disk edits and path changes require trust again")
    func diskEditsAndPathChangesRequireTrust() async throws {
        let brewfile = try Self.makeBrewfile(contents: "brew \"wget\"\n")
        let otherBrewfile = try Self.makeBrewfile(contents: "brew \"curl\"\n")
        let mock = MockCommandRunner()
        let (service, _) = makeService(mock: mock)
        service.customBrewfilePath = brewfile.path
        try service.trustReviewedBrewfile(BrewfileSnapshot.read(from: brewfile))
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
        try service.trustReviewedBrewfile(BrewfileSnapshot.read(from: brewfile))
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
        try service.trustReviewedBrewfile(BrewfileSnapshot.read(from: brewfile))
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

        service.customBrewfilePath = symlink.path
        try service.trustReviewedBrewfile(BrewfileSnapshot.read(from: symlink))
        #expect(service.brewfileSnapshot?.sourcePath == symlink.standardizedFileURL.path)
        #expect(service.brewfileSnapshot?.data == Data("brew \"wget\"\n".utf8))
        #expect(throws: BrewfileSnapshotError.notRegular) { try BrewfileReview(reading: directory) }
        #expect(throws: BrewfileSnapshotError.tooLarge) { try BrewfileReview(reading: oversized) }
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
        try service.trustReviewedBrewfile(BrewfileSnapshot.read(from: symlink))
        try FileManager.default.removeItem(at: symlink)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: secondTarget)

        await service.refreshBundle()

        #expect(service.bundleCheckStatus == .untrusted)
        #expect(mock.executedCommands.isEmpty)
    }

    @Test("Identical bytes at a new path require independent trust")
    func identicalBytesAtAnotherPath() async throws {
        let first = try Self.makeBrewfile(contents: "brew \"wget\"\n")
        let second = try Self.makeBrewfile(contents: "brew \"wget\"\n")
        defer {
            try? FileManager.default.removeItem(at: first.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: second.deletingLastPathComponent())
        }
        let mock = MockCommandRunner()
        let (service, _) = makeService(mock: mock)
        service.customBrewfilePath = first.path
        try service.trustReviewedBrewfile(BrewfileSnapshot.read(from: first))
        service.customBrewfilePath = second.path
        await service.refreshBundle()
        #expect(service.bundleCheckStatus == .untrusted)
        #expect(mock.executedCommands.isEmpty)
    }

    @Test("A FIFO is rejected without waiting for a writer")
    func fifoIsNotARegularFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pipe = directory.appendingPathComponent("Brewfile")
        #expect(mkfifo(pipe.path, 0o600) == 0)
        #expect(throws: BrewfileSnapshotError.notRegular) { try BrewfileSnapshot.read(from: pipe) }
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
