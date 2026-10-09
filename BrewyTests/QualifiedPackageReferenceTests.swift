@testable import Brewy
import Foundation
import Testing

private func tapFormula(_ name: String, tap: String) -> BrewPackage {
    BrewPackage(
        id: "formula-\(name)", name: name, version: "1.0", description: "", homepage: "",
        isInstalled: true, isOutdated: false, installedVersion: "1.0", latestVersion: "1.0",
        source: .formula, pinned: false, installedOnRequest: false, dependencies: [],
        qualifiedName: "\(tap)/\(name)"
    )
}

@Suite("Qualified package references")
@MainActor
struct QualifiedPackageReferenceTests {
    @Test("A qualified reference matches only the installed package from that tap")
    func qualifiedReferenceResolution() {
        let service = BrewService()
        service.installedFormulae = [tapFormula("foo", tap: "other/tap")]

        #expect(service.installedPackageID(for: PackageReference(name: "other/tap/foo", source: .formula)) == "formula-foo")
        #expect(service.installedPackageID(for: PackageReference(name: "wrong/tap/foo", source: .formula)) == nil)
        #expect(service.installedPackageID(for: PackageReference(name: "other/tap/foo", source: .cask)) == nil)
    }

    @Test("An ambiguous short reference matches the installed package of that name")
    func shortReferenceResolution() {
        let service = BrewService()
        service.installedFormulae = [tapFormula("foo", tap: "other/tap")]

        #expect(service.installedPackageID(for: PackageReference(name: "foo", source: .formula)) == "formula-foo")
        #expect(service.installedPackageID(for: PackageReference(name: "foo", source: .cask)) == nil)
    }

    @Test("Tap-qualified dependencies count toward dependents, leaves and dependency trees")
    func qualifiedDependencies() {
        let service = BrewService()
        service.installedFormulae = [
            tapFormula("bar", tap: "other/tap"),
            makePackage(name: "app", dependencies: ["other/tap/bar"])
        ]

        #expect(service.dependents(of: "bar").map(\.id) == ["formula-app"])
        #expect(!service.leavesPackages.map(\.id).contains("formula-bar"))
        #expect(service.reverseDependencyTree(for: "bar").map(\.packageID) == ["formula-app"])
        let forward = service.forwardDependencyTree(for: "app")
        #expect(forward.map(\.name) == ["other/tap/bar"])
        #expect(forward.map(\.packageID) == ["formula-bar"])
    }

    @Test("A dependency on another tap's package of the same name does not attach")
    func otherTapDependency() {
        let service = BrewService()
        service.installedFormulae = [
            tapFormula("bar", tap: "other/tap"),
            makePackage(name: "app", dependencies: ["wrong/tap/bar"])
        ]

        #expect(service.dependents(of: "bar").isEmpty)
        #expect(service.leavesPackages.map(\.id).contains("formula-bar"))
        #expect(service.forwardDependencyTree(for: "app").map(\.isInstalled) == [false])
    }

    @Test("Search marks a qualified result installed only for the installed tap")
    func qualifiedSearchResults() async {
        let mock = MockCommandRunner()
        let (service, _) = makeService(mock: mock)
        service.installedFormulae = [tapFormula("foo", tap: "other/tap")]
        mock.setResult(for: ["search", "--formula", "--", "foo"], output: "foo\nother/tap/foo\nwrong/tap/foo")
        mock.setResult(for: ["search", "--cask", "--", "foo"], output: "")

        await service.search(query: "foo")

        #expect(service.searchResults.map(\.name) == ["foo", "other/tap/foo", "wrong/tap/foo"])
        #expect(service.searchResults.map(\.isInstalled) == [true, true, false])
    }

    @Test("Discover marks a qualified update item installed only for the installed tap")
    func qualifiedDiscoverItems() {
        let service = BrewService()
        service.installedFormulae = [tapFormula("foo", tap: "other/tap")]
        let result = BrewUpdateResult(
            newFormulae: [
                BrewUpdateItem(name: "other/tap/foo", description: nil, source: .formula),
                BrewUpdateItem(name: "wrong/tap/foo", description: nil, source: .formula)
            ],
            newCasks: [],
            timestamp: Date()
        )

        let packages = result.discoverPackages { service.installedPackageID(for: $0) != nil }

        #expect(packages.map(\.isInstalled) == [true, false])
    }
}
