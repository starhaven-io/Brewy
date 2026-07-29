@testable import Brewy
import Foundation
import Testing

// MARK: - Search Tests

@Suite("BrewService.search()")
@MainActor
struct SearchTests {

    @Test("search returns formula and cask results")
    func searchReturnsBoth() async {
        let mock = MockCommandRunner()
        let (service, _) = makeService(mock: mock)
        mock.setResult(for: ["search", "--formula", "--", "fire"], output: "firewalld\nfirejail")
        mock.setResult(for: ["search", "--cask", "--", "fire"], output: "firefox\nfirealpaca")

        await service.search(query: "fire")

        #expect(service.searchResults.count == 4)
        let names = Set(service.searchResults.map(\.name))
        #expect(names.contains("firefox"))
        #expect(names.contains("firewalld"))
    }

    @Test("search marks installed packages")
    func searchMarksInstalled() async {
        let mock = MockCommandRunner()
        let (service, _) = makeService(mock: mock)
        service.installedFormulae = [makePackage(name: "wget")]

        mock.setResult(for: ["search", "--formula", "--", "wget"], output: "wget\nwget2")
        mock.setResult(for: ["search", "--cask", "--", "wget"], output: "")

        await service.search(query: "wget")

        let wgetResult = service.searchResults.first { $0.name == "wget" }
        let wget2Result = service.searchResults.first { $0.name == "wget2" }
        #expect(wgetResult?.isInstalled == true)
        #expect(wget2Result?.isInstalled == false)
    }

    @Test("search installed badge does not leak across sources")
    func searchInstalledBadgeIsSourceQualified() async {
        let mock = MockCommandRunner()
        let (service, _) = makeService(mock: mock)
        service.installedFormulae = [makePackage(name: "wireshark", source: .formula)]
        service.installedMasApps = [makePackage(name: "amphetamine", source: .mas)]

        mock.setResult(for: ["search", "--formula", "--", "shark"], output: "wireshark")
        mock.setResult(for: ["search", "--cask", "--", "shark"], output: "wireshark\namphetamine")

        await service.search(query: "shark")

        let formulaHit = service.searchResults.first { $0.source == .formula && $0.name == "wireshark" }
        let caskHit = service.searchResults.first { $0.source == .cask && $0.name == "wireshark" }
        let masNamedCaskHit = service.searchResults.first { $0.source == .cask && $0.name == "amphetamine" }
        #expect(formulaHit?.isInstalled == true)
        #expect(caskHit?.isInstalled == false)
        #expect(masNamedCaskHit?.isInstalled == false)
    }

    @Test("search with empty query clears results")
    func searchEmptyQueryClears() async {
        let mock = MockCommandRunner()
        let (service, _) = makeService(mock: mock)
        service.searchResults = [makePackage(name: "old-result")]

        await service.search(query: "")

        #expect(service.searchResults.isEmpty)
    }

    @Test("search handles failure gracefully")
    func searchHandlesFailure() async {
        let mock = MockCommandRunner()
        let (service, _) = makeService(mock: mock)
        mock.setResult(for: ["search", "--formula", "--", "test"], output: "Error", success: false)
        mock.setResult(for: ["search", "--cask", "--", "test"], output: "test-app")

        await service.search(query: "test")

        #expect(service.searchResults.count == 1)
        #expect(service.searchResults[0].name == "test-app")
    }

    @Test("search filters out ==> header lines")
    func searchFiltersHeaders() async {
        let mock = MockCommandRunner()
        let (service, _) = makeService(mock: mock)
        mock.setResult(for: ["search", "--formula", "--", "test"], output: "==> Formulae\ntest-formula")
        mock.setResult(for: ["search", "--cask", "--", "test"], output: "==> Casks\ntest-cask")

        await service.search(query: "test")

        let names = service.searchResults.map(\.name)
        #expect(!names.contains("==>"))
        // The header word itself must not survive tokenization as a phantom package.
        #expect(!names.contains("Formulae"))
        #expect(!names.contains("Casks"))
        #expect(names.contains("test-formula"))
        #expect(names.contains("test-cask"))
    }

    @Test("search results have correct source types")
    func searchResultSourceTypes() async {
        let mock = MockCommandRunner()
        let (service, _) = makeService(mock: mock)
        mock.setResult(for: ["search", "--formula", "--", "test"], output: "test-formula")
        mock.setResult(for: ["search", "--cask", "--", "test"], output: "test-cask")

        await service.search(query: "test")

        let formula = service.searchResults.first { $0.name == "test-formula" }
        let cask = service.searchResults.first { $0.name == "test-cask" }
        #expect(formula?.source == .formula)
        #expect(cask?.source == .cask)
    }
}
