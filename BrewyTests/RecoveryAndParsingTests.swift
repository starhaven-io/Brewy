@testable import Brewy
import Foundation
import Testing

@Suite("Recovery and parsing")
struct RecoveryAndParsingTests {
    @Test("Error-prefixed command output remains bounded")
    func errorLineBounded() {
        let error = BrewError.commandFailed(command: "info", output: "Error: " + String(repeating: "x", count: 2_000))
        #expect(error.localizedDescription.count == 801)
        #expect(error.localizedDescription.hasPrefix("Error: "))
        #expect(error.localizedDescription.hasSuffix("…"))
    }

    @Test("Malformed cask dependencies fail decoding", arguments: [
        #""invalid""#, #"["wget"]"#, #"{"formula":["wget",1]}"#, #"{"cask":{}}"#
    ])
    func malformedDependenciesRejected(value: String) {
        let data = Data("{\"token\":\"example\",\"depends_on\":\(value)}".utf8)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(CaskJSON.self, from: data) }
    }

    @Test("Missing, null and legacy empty cask dependencies remain valid", arguments: ["{}", "[]", "null"])
    func optionalDependenciesAccepted(value: String) throws {
        let data = Data("{\"token\":\"example\",\"depends_on\":\(value)}".utf8)
        let cask = try JSONDecoder().decode(CaskJSON.self, from: data)
        #expect(cask.dependencyReferences.isEmpty)
    }

    @Test("A successful HTTP response still requires a valid archived flag", arguments: [
        "{}", #"{"archived":null}"#, #"{"archived":"false"}"#
    ])
    func incompleteHealthIsUnknown(body: String) async throws {
        let response = try #require(HTTPURLResponse(
            url: URL(string: "https://api.github.com/repos/example/homebrew-tap")!,
            statusCode: 200, httpVersion: nil, headerFields: nil
        ))
        let status = await TapHealthChecker.mapResponse(
            statusCode: 200, data: Data(body.utf8), response: response, owner: "example", repo: "homebrew-tap"
        )
        #expect(status.status == .unknown)
        let healthy = await TapHealthChecker.mapResponse(
            statusCode: 200, data: Data(#"{"archived":false}"#.utf8),
            response: response, owner: "example", repo: "homebrew-tap"
        )
        #expect(healthy.status == .healthy)
    }

    @Test("Interrupted security checks override partial verdict output", arguments: [true, false])
    func interruptedSecurityChecks(cancelled: Bool) {
        let suffix = cancelled ? "Command was cancelled." : "Command timed out."
        let details = ApplicationSecurityParser.parse(
            applicationURL: URL(fileURLWithPath: "/Applications/Example.app"),
            signingMetadata: CommandResult(output: "", success: false),
            signingVerification: CommandResult(
                output: "code object is not signed at all\n" + suffix, success: false, cancelled: cancelled
            ),
            gatekeeperAssessment: CommandResult(
                output: "rejected\n" + suffix, success: false, cancelled: cancelled
            )
        )
        #expect(details.signingStatus == .unavailable)
        #expect(details.gatekeeperStatus == .unavailable)
    }

    @MainActor
    @Test("Cache size rejects negative and overflowing disk usage", arguments: ["-1", String(Int64.max)])
    func cacheSizeRejectsInvalidNumber(size: String) async {
        let mock = MockCommandRunner()
        let service = BrewService(commandRunner: mock)
        mock.setResult(for: ["--cache"], output: "/tmp/brewy-cache")
        mock.setResult(for: ["-sk", "--", "/tmp/brewy-cache"], output: "\(size)\t/tmp/brewy-cache")
        #expect(await service.cacheSize() == 0)
    }

    @MainActor
    @Test("Failed cache path resolution never invokes disk usage")
    func cachePathFailureStops() async {
        let mock = MockCommandRunner()
        let service = BrewService(commandRunner: mock)
        mock.setResult(for: ["--cache"], output: "Permission denied", success: false)
        #expect(await service.cacheSize() == 0)
        #expect(mock.executedCommands == [["--cache"]])
    }

    @MainActor
    @Test("Tap migration reports failure to restore the original tap")
    func tapRollbackFailureIsVisible() async {
        let mock = MockCommandRunner()
        let service = BrewService(commandRunner: mock)
        setupRefreshMock(mock)
        mock.setResult(for: ["untap", "--", "old/tap"], output: "Untapped")
        mock.setResult(for: ["tap", "--", "new/tap"], output: "New tap unavailable", success: false)
        mock.setResult(for: ["tap", "--", "old/tap"], output: "Original tap unavailable", success: false)
        let result = await service.migrateTap(from: "old/tap", to: "new/tap")
        #expect(!result.success)
        #expect(result.output.contains("Unable to restore old/tap"))
        #expect(result.output.contains("Re-add old/tap"))
        #expect(service.lastError?.localizedDescription.contains("Re-add old/tap") == true)
        #expect(mock.executedCommands.filter { ["tap", "untap"].contains($0.first ?? "") } == [
            ["untap", "--", "old/tap"], ["tap", "--", "new/tap"], ["tap", "--", "old/tap"]
        ])
    }
}
