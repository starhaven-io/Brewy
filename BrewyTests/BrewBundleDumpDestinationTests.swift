@testable import Brewy
import Darwin
import Foundation
import Testing

@Suite("Brew Bundle Dump Destinations")
@MainActor
struct BrewBundleDumpDestinationTests {
    @Test("dumpBundle preserves symbolic links and trusts the chosen path", arguments: ["absolute", "relative", "chain"])
    func dumpBundlePreservesSymbolicLink(kind: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("Target")
        try Data("old contents\n".utf8).write(to: target)
        let links = directory.appendingPathComponent("Links")
        try FileManager.default.createDirectory(at: links, withIntermediateDirectories: false)
        let chosen = links.appendingPathComponent("Brewfile")
        let intermediate = links.appendingPathComponent("Intermediate")
        if kind == "chain" {
            try FileManager.default.createSymbolicLink(atPath: intermediate.path, withDestinationPath: "../Target")
        }
        let destination = kind == "absolute" ? target.path : kind == "relative" ? "../Target" : "Intermediate"
        try FileManager.default.createSymbolicLink(atPath: chosen.path, withDestinationPath: destination)
        let generatedData = Data("brew \"wget\"\n".utf8)
        let mock = Self.dumpRunner(data: generatedData)
        let (service, _) = makeService(mock: mock)

        let result = await service.dumpBundle(to: chosen)

        #expect(result.success)
        #expect(try FileManager.default.attributesOfItem(atPath: chosen.path)[.type] as? FileAttributeType == .typeSymbolicLink)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: chosen.path) == destination)
        if kind == "chain" {
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: intermediate.path) == "../Target")
        }
        #expect(try Data(contentsOf: target) == generatedData)
        #expect(service.customBrewfilePath == chosen.path)
        #expect(service.brewfileSnapshot?.sourcePath == chosen.standardizedFileURL.path)
        #expect(service.brewfileSnapshot?.data == generatedData)
        #expect(service.trustedBrewfileDigest == (try BrewfileSnapshot(sourcePath: chosen.path, data: generatedData)).digest)
        #expect(service.bundleCheckStatus == .satisfied)
        #expect(service.actionHistory.first?.arguments == ["bundle", "dump", "--force", "--file", chosen.path])
        #expect(result.output == "Created Brewfile at \(chosen.path).")
        service.brewfileSnapshot = nil

        await service.refreshBundle()

        #expect(service.bundleCheckStatus == .satisfied)
        #expect(service.brewfileSnapshot?.sourcePath == chosen.standardizedFileURL.path)
        #expect(mock.standardInputs.count == 10)
        #expect(mock.standardInputs.allSatisfy { $0.data == generatedData })
    }

    enum RejectedTarget: CaseIterable {
        case dangling, directory, loop, readOnly, unwritableParent, oversized, fifo
    }

    @Test("dumpBundle rejects invalid linked targets without changing files or trust", arguments: RejectedTarget.allCases)
    func dumpBundleRejectsLinkedTarget(kind: RejectedTarget) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let parent = directory.appendingPathComponent("Dotfiles")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let target = parent.appendingPathComponent("Target")
        let chosen = directory.appendingPathComponent("Brewfile")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let originalData = try Self.prepareRejectedTarget(kind, target: target, chosen: chosen)
        try FileManager.default.createSymbolicLink(at: chosen, withDestinationURL: target)
        let originalFiles = try FileManager.default.contentsOfDirectory(atPath: parent.path)
        let previous = directory.appendingPathComponent("Previous")
        try Data("brew \"curl\"\n".utf8).write(to: previous)
        let mock = Self.dumpRunner(data: Data("brew \"wget\"\n".utf8))
        let (service, _) = makeService(mock: mock)
        service.customBrewfilePath = previous.path
        #expect(service.trustBrewfile(at: previous))
        let previousDigest = service.trustedBrewfileDigest

        let result = await service.dumpBundle(to: chosen)

        #expect(!result.success)
        #expect(result.output.hasPrefix("Unable to write Brewfile at \(chosen.path):"))
        #expect(service.lastError != nil)
        #expect(service.actionHistory.count == 1)
        #expect(service.actionHistory.first?.status == .failure)
        #expect(service.actionHistory.first?.arguments == ["bundle", "dump", "--force", "--file", chosen.path])
        #expect(service.customBrewfilePath == previous.path)
        #expect(service.trustedBrewfilePath == previous.standardizedFileURL.path)
        #expect(service.trustedBrewfileDigest == previousDigest)
        #expect(service.brewfileSnapshot?.sourcePath == previous.standardizedFileURL.path)
        #expect(mock.executedCommands.count == 1)
        #expect(mock.standardInputs.isEmpty)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: chosen.path) == target.path)
        #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path) == originalFiles)
        if let originalData {
            #expect(try Data(contentsOf: target) == originalData)
        } else if kind == .dangling {
            #expect(!FileManager.default.fileExists(atPath: target.path))
        } else if kind == .loop {
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: target.path) == chosen.path)
        } else {
            var status = stat()
            #expect(lstat(target.path, &status) == 0)
            #expect(status.st_mode & S_IFMT == (kind == .directory ? S_IFDIR : S_IFIFO))
        }
    }

    @Test("history retry dumps through the recorded symbolic link")
    func retryDumpThroughSymbolicLink() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("Target")
        let chosen = directory.appendingPathComponent("Brewfile")
        try Data().write(to: target)
        try FileManager.default.createSymbolicLink(at: chosen, withDestinationURL: target)
        let data = Data("brew \"wget\"\n".utf8)
        let (service, _) = makeService(mock: Self.dumpRunner(data: data))
        let arguments = ["bundle", "dump", "--force", "--file", chosen.path]
        let entry = ActionHistoryEntry(
            id: UUID(), command: "bundle", arguments: arguments,
            packageName: nil, packageSource: nil, status: .failure, output: "Failed", timestamp: Date()
        )

        await service.retryAction(entry)

        #expect(service.actionHistory.first?.status == .success)
        #expect(service.actionHistory.first?.arguments == arguments)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: chosen.path) == target.path)
        #expect(try Data(contentsOf: target) == data)
        #expect(service.customBrewfilePath == chosen.path)
        #expect(service.bundleCheckStatus == .satisfied)
    }

    private static func prepareRejectedTarget(_ kind: RejectedTarget, target: URL, chosen: URL) throws -> Data? {
        switch kind {
        case .dangling:
            return nil
        case .directory:
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            return nil
        case .loop:
            try FileManager.default.createSymbolicLink(at: target, withDestinationURL: chosen)
            return nil
        case .fifo:
            try #require(mkfifo(target.path, 0o600) == 0)
            return nil
        case .readOnly, .unwritableParent, .oversized:
            let data = kind == .oversized
                ? Data(repeating: 0x41, count: BrewfileSnapshot.maximumByteCount + 1)
                : Data("old contents\n".utf8)
            try data.write(to: target)
            if kind == .readOnly || kind == .unwritableParent {
                let restricted = kind == .readOnly ? target : target.deletingLastPathComponent()
                try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: restricted.path)
                try #require(!FileManager.default.isWritableFile(atPath: restricted.path))
            }
            return data
        }
    }

    private static func dumpRunner(data: Data) -> MockCommandRunner {
        let mock = MockCommandRunner()
        mock.setCommandHandler { arguments in
            guard Array(arguments.prefix(4)) == ["bundle", "dump", "--force", "--file"],
                  let path = arguments.last else { return nil }
            do {
                try data.write(to: URL(fileURLWithPath: path))
                return CommandResult(output: "", success: true)
            } catch {
                return CommandResult(output: error.localizedDescription, success: false)
            }
        }
        for type in BrewBundleEntryType.allCases {
            mock.setResult(for: ["bundle", "list", type.listFlag, "--file=-"], output: "")
        }
        mock.setResult(for: ["bundle", "check", "--verbose", "--file=-"], output: "")
        return mock
    }
}
