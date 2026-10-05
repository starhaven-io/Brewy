@testable import Brewy
import Foundation
import Testing

@Suite("Executable Path Validation")
struct ExecutablePathValidationTests {
    @Test("Directories and non-executable files are rejected, executable symlinks work")
    func regularExecutablePaths() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("brew")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: file)
        #expect(!CommandRunner.isRegularExecutable(atPath: directory.path))
        #expect(CommandRunner.resolvedBrewPath(preferred: directory.path) != directory.path)
        #expect(!CommandRunner.isRegularExecutable(atPath: file.path))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        #expect(CommandRunner.isRegularExecutable(atPath: file.path))
        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(CommandRunner.isRegularExecutable(atPath: link.path))
        #expect(CommandRunner.resolvedBrewPath(preferred: link.path) == link.path)
    }
    @Test("A directory at the mas path is unavailable and never executed")
    @MainActor
    func masDirectoryIsNotAvailable() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let mock = MockCommandRunner()
        let service = BrewService(commandRunner: mock, masExecutablePath: directory.path)
        let installed = await service.fetchInstalledMasApps()
        let outdated = await service.fetchOutdatedMasApps()
        #expect(installed?.packages.isEmpty == true)
        #expect(outdated?.isEmpty == true)
        #expect(!service.isMasAvailable)
        #expect(mock.executedExecutables.isEmpty)
    }

}
