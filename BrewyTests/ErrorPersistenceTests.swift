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

    @Test("addTap exposes the full failed command to the root error presenter")
    func addTapExposesGlobalFailure() async {
        let mock = MockCommandRunner()
        let (service, _) = makeService(mock: mock)
        setupRefreshMock(mock)
        mock.setResult(for: ["tap", "user/repo"], output: "", success: false)

        let result = await service.addTap(name: "user/repo")

        #expect(!result.success)
        #expect(service.lastError?.localizedDescription == "brew tap user/repo failed.")
    }

    @Test("performBrewAction preserves command failure after refresh")
    func brewActionPreservesFailureAfterRefresh() async {
        let mock = MockCommandRunner()
        let (service, _) = makeService(mock: mock)
        setupRefreshMock(mock)
        mock.setResult(for: ["autoremove"], output: "autoremove failed", success: false)

        await service.performBrewAction(["autoremove"], refreshAfter: true)

        #expect(service.lastError != nil)
        #expect(service.lastError?.localizedDescription.contains("autoremove failed") == true)
    }

    @Test("upgradeSelected preserves command failure after refresh")
    func upgradeSelectedPreservesFailureAfterRefresh() async {
        let mock = MockCommandRunner()
        let (service, _) = makeService(mock: mock)
        setupRefreshMock(mock)
        mock.setResult(for: ["upgrade", "--", "wget"], output: "upgrade failed", success: false)

        await service.upgradeSelected(packages: [makePackage(name: "wget", isOutdated: true)])

        #expect(service.lastError != nil)
        #expect(service.lastError?.localizedDescription.contains("upgrade failed") == true)
    }

    @Test("background refresh failure stays out of the modal error")
    func backgroundRefreshFailureIsNonModal() async {
        let mock = MockCommandRunner()
        let (service, _) = makeService(mock: mock)
        setupRefreshMock(mock)
        mock.setResult(for: ["info", "--installed", "--json=v2"], output: "brew broke", success: false)

        await service.refresh(isUserInitiated: false)

        #expect(service.lastError == nil)
        #expect(service.backgroundRefreshError != nil)
        #expect(service.backgroundRefreshError?.localizedDescription.contains("brew broke") == true)
    }

    @Test("user-initiated refresh failure raises the modal error")
    func userRefreshFailureIsModal() async {
        let mock = MockCommandRunner()
        let (service, _) = makeService(mock: mock)
        setupRefreshMock(mock)
        mock.setResult(for: ["outdated", "--json=v2"], output: "brew broke", success: false)

        await service.refresh()

        #expect(service.lastError != nil)
        #expect(service.backgroundRefreshError == nil)
    }

    @Test("clean refresh clears a stale background refresh error")
    func cleanRefreshClearsBackgroundError() async {
        let mock = MockCommandRunner()
        let (service, _) = makeService(mock: mock)
        setupRefreshMock(mock)
        mock.setResult(for: ["tap-info", "--json=v1", "--installed"], output: "network down", success: false)

        await service.refresh(isUserInitiated: false)
        #expect(service.backgroundRefreshError != nil)

        mock.setResult(for: ["tap-info", "--json=v1", "--installed"], output: TestJSON.taps)
        await service.refresh(isUserInitiated: false)

        #expect(service.backgroundRefreshError == nil)
        #expect(service.lastError == nil)
    }

    @Test("failing background refresh keeps the prior package lists")
    func backgroundFailureKeepsPriorLists() async {
        let mock = MockCommandRunner()
        let (service, _) = makeService(mock: mock)
        setupRefreshMock(mock)

        await service.refresh(isUserInitiated: false)
        #expect(!service.installedFormulae.isEmpty)

        mock.setResult(for: ["info", "--installed", "--json=v2"], output: "brew broke", success: false)
        await service.refresh(isUserInitiated: false)

        #expect(!service.installedFormulae.isEmpty)
        #expect(service.lastError == nil)
        #expect(service.backgroundRefreshError != nil)
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
