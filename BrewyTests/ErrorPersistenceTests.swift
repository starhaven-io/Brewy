@testable import Brewy
import Foundation
import Testing

@Suite("BrewService error persistence")
@MainActor
struct ErrorPersistenceTests {

    @Test("removeTap preserves command failure after refresh")
    func removeTapPreservesFailure() async {
        let mock = MockCommandRunner()
        let (service, _) = makeService(mock: mock)
        setupRefreshMock(mock)
        mock.setResult(for: ["untap", "user/repo"], output: "Refusing to untap", success: false)

        let result = await service.removeTap(name: "user/repo")

        #expect(!result.success)
        #expect(service.lastError != nil)
        #expect(service.lastError?.localizedDescription.contains("Refusing to untap") == true)
    }

    @Test("queued refresh preserves an error set while waiting")
    func queuedRefreshPreservesLateError() async {
        let mock = MockCommandRunner()
        let (service, _) = makeService(mock: mock)
        setupRefreshMock(mock)
        let delayedCommand = ["info", "--installed", "--json=v2"]
        mock.setDelay(for: delayedCommand, duration: .milliseconds(100))

        let refreshTask = Task { await service.refresh() }
        while !mock.executedCommands.contains(delayedCommand) {
            try? await Task.sleep(for: .milliseconds(1))
        }

        await service.refresh()
        service.lastError = .commandFailed(command: "late", output: "late failure")

        await refreshTask.value

        #expect(service.lastError != nil)
        #expect(service.lastError?.localizedDescription.contains("late failure") == true)
    }
}
