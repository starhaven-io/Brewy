@testable import Brewy
import Foundation
import Testing

@Suite("Qualified Homebrew command targets")
@MainActor
struct QualifiedPackageCommandTests {
    @Test("Third-party formula lookups retain the display name and use full_name")
    func formulaLookups() async throws {
        let json = """
        {"formulae":[{"name":"foo","full_name":"other/tap/foo","versions":{"stable":"1.0"},
        "installed":[{"version":"1.0"}]}],"casks":[]}
        """
        let response = try JSONDecoder().decode(BrewInfoResponse.self, from: Data(json.utf8))
        let package = try #require(response.formulae?.first?.toPackage())
        let mock = MockCommandRunner()
        let (service, _) = makeService(mock: mock)
        mock.setResult(for: ["info", "--", "other/tap/foo"], output: "third-party foo")
        mock.setResult(for: ["info", "--json=v2", "--", "other/tap/foo"], output: json)

        let info = await service.info(for: package)
        let detail = await service.fetchPackageDetail(for: package)

        #expect(package.name == "foo")
        #expect(package.id == "formula-foo")
        #expect(info == "third-party foo")
        #expect(detail != nil)
        #expect(mock.executedCommands.contains(["info", "--", "other/tap/foo"]))
        #expect(mock.executedCommands.contains(["info", "--json=v2", "--", "other/tap/foo"]))
    }

    @Test("Third-party cask lookup uses full_token")
    func caskLookup() async throws {
        let json = """
        {"formulae":[],"casks":[{"token":"foo","full_token":"other/tap/foo","version":"1.0"}]}
        """
        let response = try JSONDecoder().decode(BrewInfoResponse.self, from: Data(json.utf8))
        let package = try #require(response.casks?.first?.toPackage())
        let mock = MockCommandRunner()
        let (service, _) = makeService(mock: mock)
        mock.setResult(for: ["info", "--cask", "--", "other/tap/foo"], output: "third-party cask")

        let info = await service.info(for: package)

        #expect(package.name == "foo")
        #expect(package.id == "cask-foo")
        #expect(info == "third-party cask")
        #expect(mock.executedCommands.contains(["info", "--cask", "--", "other/tap/foo"]))
    }

    @Test("Direct and selected actions use the qualified formula target")
    func qualifiedActions() async throws {
        let json = """
        {"formulae":[{"name":"foo","full_name":"other/tap/foo","versions":{"stable":"1.0"}}],"casks":[]}
        """
        let response = try JSONDecoder().decode(BrewInfoResponse.self, from: Data(json.utf8))
        let package = try #require(response.formulae?.first?.toPackage())
        let mock = MockCommandRunner()
        let (service, _) = makeService(mock: mock)
        setupRefreshMock(mock)
        mock.setResult(for: ["install", "--", "other/tap/foo"], output: "Installed")
        mock.setResult(for: ["upgrade", "--", "other/tap/foo"], output: "Upgraded")

        await service.install(package: package)
        await service.upgradeSelected(packages: [package])

        #expect(mock.executedCommands.contains(["install", "--", "other/tap/foo"]))
        #expect(mock.executedCommands.contains(["upgrade", "--", "other/tap/foo"]))
    }

    @Test("Outdated formula JSON joins the installed tap formula")
    func outdatedFormulaMerge() throws {
        let installedJSON = """
        {"formulae":[{"name":"foo","full_name":"other/tap/foo","versions":{"stable":"2.0"},
        "installed":[{"version":"1.0"}]}],"casks":[]}
        """
        let outdatedJSON = """
        {"formulae":[{"name":"other/tap/foo","installed_versions":["1.0"],
        "current_version":"2.0","pinned":false}],"casks":[]}
        """
        let installed = try #require(JSONDecoder().decode(
            BrewInfoResponse.self, from: Data(installedJSON.utf8)
        ).formulae?.first?.toPackage())
        let outdated = try #require(JSONDecoder().decode(
            BrewOutdatedResponse.self, from: Data(outdatedJSON.utf8)
        ).formulae?.first?.toPackage())
        let merged = BrewService.mergeRefreshPackages(
            formulae: [installed], casks: [], masApps: [], outdated: [outdated]
        )

        #expect(outdated.id == "formula-foo")
        #expect(outdated.name == "foo")
        #expect(outdated.brewName == "other/tap/foo")
        #expect(merged.formulae.first?.isOutdated == true)
        #expect(merged.outdated.first?.id == installed.id)
        #expect(merged.outdated.first?.brewName == "other/tap/foo")
    }

    @Test("Info cache distinguishes a core placeholder from a tapped package")
    func infoCacheUsesCommandTarget() async throws {
        let json = """
        {"formulae":[{"name":"foo","full_name":"other/tap/foo","versions":{"stable":"1.0"}}],"casks":[]}
        """
        let installed = try #require(JSONDecoder().decode(
            BrewInfoResponse.self, from: Data(json.utf8)
        ).formulae?.first?.toPackage())
        let core = makePackage(name: "foo")
        let mock = MockCommandRunner()
        let (service, _) = makeService(mock: mock)
        mock.setResult(for: ["info", "--", "foo"], output: "core foo")
        mock.setResult(for: ["info", "--", "other/tap/foo"], output: "tap foo")

        #expect(await service.info(for: core) == "core foo")
        #expect(await service.info(for: installed) == "tap foo")
        #expect(mock.executedCommands.contains(["info", "--", "other/tap/foo"]))
    }

    @Test("Keg actions keep the installed short name after a tap migration")
    func kegActionsUseInstalledName() async throws {
        let json = """
        {"formulae":[{"name":"foo","full_name":"other/tap/foo","versions":{"stable":"1.0"},
        "installed":[{"version":"1.0"}]}],"casks":[]}
        """
        let package = try #require(JSONDecoder().decode(
            BrewInfoResponse.self, from: Data(json.utf8)
        ).formulae?.first?.toPackage())
        let mock = MockCommandRunner()
        let (service, _) = makeService(mock: mock)
        setupRefreshMock(mock)
        for action in ["uninstall", "link", "unlink"] {
            mock.setResult(for: [action, "--", "foo"], output: "Done")
        }

        await service.uninstall(package: package)
        await service.link(package: package)
        await service.unlink(package: package)

        for action in ["uninstall", "link", "unlink"] {
            #expect(mock.executedCommands.contains([action, "--", "foo"]))
        }
    }

    @Test("Stale detail from another tap cannot replace package metadata")
    func enrichmentRejectsDifferentTarget() throws {
        let json = """
        {"formulae":[
        {"name":"foo","full_name":"other/tap/foo","desc":"current","versions":{"stable":"1.0"}},
        {"name":"foo","full_name":"wrong/tap/foo","desc":"stale","versions":{"stable":"1.0"}}
        ],"casks":[]}
        """
        let formulae = try #require(JSONDecoder().decode(
            BrewInfoResponse.self, from: Data(json.utf8)
        ).formulae)
        let current = formulae[0].toPackage()
        let stale = formulae[1].toPackage()

        #expect(current.enriched(with: stale) == current)
    }

    @Test("Brewfile status matches the qualified tap target")
    func bundleStatusUsesQualifiedTarget() throws {
        let json = """
        {"formulae":[{"name":"foo","full_name":"other/tap/foo","versions":{"stable":"1.0"}}],"casks":[]}
        """
        let package = try #require(JSONDecoder().decode(
            BrewInfoResponse.self, from: Data(json.utf8)
        ).formulae?.first?.toPackage())
        let (service, _) = makeService(mock: MockCommandRunner())
        service.installedFormulae = [package]
        service.bundleEntries = [
            BrewBundleEntry(type: .formula, name: "other/tap/foo", status: .missing),
            BrewBundleEntry(type: .formula, name: "foo", status: .missing),
            BrewBundleEntry(type: .formula, name: "wrong/tap/foo", status: .missing)
        ]

        service.updateBundleEntryStatuses()

        #expect(service.bundleEntries.map(\.status) == [.installed, .installed, .missing])
    }

    @Test("Tap membership matches qualified names without adopting a core name collision")
    func tapMembershipUsesQualifiedTarget() throws {
        let json = """
        {"formulae":[{"name":"foo","full_name":"other/tap/foo","versions":{"stable":"1.0"}}],
        "casks":[{"token":"app","full_token":"other/tap/app","version":"1.0"}]}
        """
        let response = try JSONDecoder().decode(BrewInfoResponse.self, from: Data(json.utf8))
        let formula = try #require(response.formulae?.first?.toPackage())
        let cask = try #require(response.casks?.first?.toPackage())
        let coreFormula = makePackage(name: "foo")
        let coreCask = makePackage(name: "app", source: .cask)
        let tap = BrewTap(
            name: "other/tap", remote: "", isOfficial: false,
            formulaNames: ["other/tap/foo"], caskTokens: ["other/tap/app"]
        )

        #expect(tap.installedFormulae(in: [coreFormula, formula]) == [formula])
        #expect(tap.installedCasks(in: [coreCask, cask]) == [cask])
    }
}
