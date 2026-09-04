@testable import Brewy
import Foundation
import Testing

@Suite("Brew Bundle History Retry")
@MainActor
struct BundleRetryTests {
    @Test("retrying bundle dump restores trust and refreshes bundle state")
    func retryBundleDumpRestoresPostconditions() async throws {
        let brewfile = try Self.makeBrewfile()
        let arguments = ["bundle", "dump", "--force", "--file", brewfile.path]
        let entry = ActionHistoryEntry(
            id: UUID(), command: "bundle", arguments: arguments,
            packageName: nil, packageSource: nil,
            status: .failure, output: "brew crashed", timestamp: Date()
        )
        let mock = MockCommandRunner()
        let (service, _) = makeService(mock: mock)
        let generatedData = Data("brew \"wget\"\n".utf8)
        mock.setCommandHandler { command in
            guard Array(command.prefix(4)) == ["bundle", "dump", "--force", "--file"],
                  let path = command.last else { return nil }
            do {
                try generatedData.write(to: URL(fileURLWithPath: path))
                return CommandResult(output: "Created Brewfile", success: true)
            } catch {
                return CommandResult(output: error.localizedDescription, success: false)
            }
        }
        for flag in ["--formula", "--cask", "--tap", "--mas"] {
            mock.setResult(for: ["bundle", "list", flag, "--file=-"], output: "")
        }
        mock.setResult(
            for: ["bundle", "check", "--verbose", "--file=-"],
            output: "The Brewfile's dependencies are satisfied.\n"
        )

        await service.retryAction(entry)

        #expect(service.customBrewfilePath == brewfile.path)
        #expect(service.trustedBrewfilePath == brewfile.path)
        #expect(!service.trustedBrewfileDigest.isEmpty)
        #expect(service.bundleCheckStatus == .satisfied)
    }

    private static func makeBrewfile() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrewyBundleRetryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let brewfile = directory.appendingPathComponent("Brewfile")
        try "".write(to: brewfile, atomically: true, encoding: .utf8)
        return brewfile
    }
}
