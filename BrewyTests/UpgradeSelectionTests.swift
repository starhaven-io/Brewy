@testable import Brewy
import Testing

@Suite("Upgrade selection")
@MainActor
struct UpgradeSelectionTests {
    @Test("Selected upgrades resolve from inventory despite filtered search results")
    func upgradesHiddenSelections() async {
        let mock = MockCommandRunner()
        let (service, _) = makeService(mock: mock)
        let formula = makePackage(name: "wget", isOutdated: true)
        let cask = makePackage(name: "firefox", source: .cask, isOutdated: true)
        service.outdatedPackages = [formula, cask]
        service.searchResults = [formula]
        mock.setResult(for: ["upgrade", "--", "wget"], output: "Upgraded wget")
        mock.setResult(for: ["upgrade", "--cask", "--", "firefox"], output: "Upgraded Firefox")
        setupRefreshMock(mock)

        await service.upgradeSelected(packageIDs: [formula.id, cask.id])

        #expect(mock.executedCommands.filter { $0.first == "upgrade" } == [
            ["upgrade", "--", "wget"], ["upgrade", "--cask", "--", "firefox"]
        ])
    }

    @Test("Stale selections and Mac App Store IDs do not add upgrade targets")
    func excludesUnavailableSelections() async {
        let mock = MockCommandRunner()
        let (service, _) = makeService(mock: mock)
        let formula = makePackage(name: "wget", isOutdated: true)
        let current = makePackage(name: "jq")
        let mas = makePackage(name: "Xcode", source: .mas, isOutdated: true)
        service.outdatedPackages = [formula, mas]
        service.installedFormulae = [formula, current]
        service.searchResults = [current]
        mock.setResult(for: ["upgrade", "--", "wget"], output: "Upgraded wget")
        setupRefreshMock(mock)

        await service.upgradeSelected(packageIDs: [formula.id, current.id, mas.id, "formula-removed"])

        #expect(mock.executedCommands.filter { $0.first == "upgrade" } == [["upgrade", "--", "wget"]])
    }

    @Test("An entirely stale selection never becomes upgrade all")
    func staleSelectionDoesNothing() async {
        let mock = MockCommandRunner()
        let (service, _) = makeService(mock: mock)
        service.outdatedPackages = [makePackage(name: "wget", isOutdated: true)]

        await service.upgradeSelected(packageIDs: ["formula-removed"])
        await service.upgradeSelected(packageIDs: [])

        #expect(mock.executedCommands.isEmpty)
        #expect(!service.isPerformingAction)
    }
}
