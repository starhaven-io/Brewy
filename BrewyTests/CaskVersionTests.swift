@testable import Brewy
import Foundation
import Testing

@Suite("Cask version sources")
struct CaskVersionTests {
    @Test("App metadata never replaces recorded versions or invents a build match", arguments: [
        ("156.0.1", "157.0", "157.0"),
        ("156.0.1", "157.0", "158.0"),
        ("5.8.1,2349", "5.8.1,2349", "5.8.1"),
        ("5.8.1,2348", "5.8.1,2349", "5.8.1"),
        ("4.93.0,240920", "4.93.0,240920", "4.93.0"),
        ("6.4.5.1000", "6.4.5.1000", "6.4.5"),
        ("0.741.19.7411056,5f7ed526d8884288", "0.740.19.7400931,older", "0.0.0.1"),
        ("latest", "latest", "1.2.3")
    ])
    func keepsVersionSourcesSeparate(recorded: String, latest: String, appVersion: String) throws {
        let package = try decodeVersionFixture(recorded: recorded, latest: latest, bundleJSON: "\"\(appVersion)\"").toPackage()

        #expect(package.version == recorded)
        #expect(package.installedVersion == recorded)
        #expect(package.latestVersion == latest)
        #expect(package.displayVersion == recorded)
        #expect(package.appVersion == appVersion)
        #expect(!package.isOutdated)
    }

    @Test("Missing, malformed, or unusable app metadata does not break the inventory", arguments: [
        nil, "null", "\"\"", "\"  \"", "\"0\"", "\"0.0\"", "123", "false", "[]", "{}"
    ] as [String?])
    func ignoresUnusableAppVersion(bundleJSON: String?) throws {
        let package = try decodeVersionFixture(bundleJSON: bundleJSON).toPackage()

        #expect(package.version == "156.0.1")
        #expect(package.installedVersion == "156.0.1")
        #expect(package.appVersion == nil)
    }

    @Test("Only self-updating casks expose app metadata", arguments: [nil, "null", "false", "123"] as [String?])
    func ignoresOtherCasks(autoUpdatesJSON: String?) throws {
        let package = try decodeVersionFixture(autoUpdatesJSON: autoUpdatesJSON).toPackage()

        #expect(package.version == "156.0.1")
        #expect(package.appVersion == nil)
    }

    @Test("Ambiguous or missing application artifacts do not expose an arbitrary app version", arguments: [0, 2])
    func requiresSingleApp(appCount: Int) throws {
        let package = try decodeVersionFixture(appCount: appCount).toPackage()

        #expect(package.appVersion == nil)
        #expect(package.version == "156.0.1")
    }
}

@Suite("Cask app version refresh")
@MainActor
struct CaskVersionRefreshTests {
    @Test("Refresh preserves recorded upgrade comparisons and Homebrew eligibility",
          arguments: [("157.0", false), ("158.0", false), ("156.0.1", true), ("156.0.1", false)])
    func refreshPreservesHomebrewEligibility(appVersion: String, isOutdated: Bool) async throws {
        let mock = MockCommandRunner()
        let (service, _) = makeService(mock: mock)
        setupRefreshMock(mock)
        mock.setResult(for: ["info", "--installed", "--json=v2"], output: installedJSON(appVersion: appVersion))
        let outdatedJSON = """
        {"formulae":[],"casks":[{"name":"firefox","installed_versions":["155.0"],"current_version":"157.0"}]}
        """
        mock.setResult(for: ["outdated", "--json=v2"], output: isOutdated ? outdatedJSON : TestJSON.emptyOutdated)

        await service.refresh()

        let firefox = try #require(service.installedCasks.first)
        #expect(firefox.version == "155.0")
        #expect(firefox.installedVersion == "155.0")
        #expect(firefox.appVersion == appVersion)
        #expect(firefox.isOutdated == isOutdated)
        #expect(service.allInstalled.first?.appVersion == appVersion)
        #expect(service.homebrewOutdatedPackages.isEmpty == !isOutdated)
        if isOutdated {
            #expect(service.homebrewOutdatedPackages.first?.appVersion == appVersion)
            #expect(service.homebrewOutdatedPackages.first?.displayVersion == "155.0 → 157.0")
        }
        #expect(mock.executedCommands.filter { $0.first == "outdated" } == [["outdated", "--json=v2"]])
    }

    @Test("A placeholder cannot hide the recorded downgrade in an outdated row")
    func preservesDowngradeComparison() throws {
        let cask = try decodeVersionFixture(recorded: "0.741.19,newer", latest: "0.740.19,older", bundleJSON: "\"0.0.0.1\"")
        let package = cask.toPackage()
        let outdated = makePackage(name: "firefox", source: .cask, isOutdated: true, latestVersion: "0.740.19,older")
        let merged = BrewService.mergeOutdatedStatus(package, outdatedByID: [outdated.id: outdated])

        #expect(merged.displayVersion == "0.741.19,newer → 0.740.19,older")
        #expect(merged.appVersion == "0.0.0.1")
    }

    @Test("A self-update changes observation and cache identities without changing the Homebrew record")
    func refreshTracksSelfUpdate() async throws {
        let mock = MockCommandRunner()
        let (service, _) = makeService(mock: mock)
        setupRefreshMock(mock)
        mock.setResult(for: ["outdated", "--json=v2"], output: TestJSON.emptyOutdated)
        mock.setResult(for: ["info", "--installed", "--json=v2"], output: installedJSON(appVersion: "157.0"))
        await service.refresh()
        let original = try #require(service.installedCasks.first)
        service.infoCache[original.id] = "Old app metadata"

        mock.setResult(for: ["info", "--installed", "--json=v2"], output: installedJSON(appVersion: "158.0"))
        await service.refresh()
        let updated = try #require(service.installedCasks.first)

        #expect(updated.id == original.id)
        #expect(updated.version == original.version)
        #expect(updated != original)
        #expect(updated.versionIdentity != original.versionIdentity)
        #expect(service.allInstalled.first?.appVersion == "158.0")
        #expect(service.infoCache[original.id] == nil)
        #expect(service.outdatedPackages.isEmpty)
    }

    @Test("Detail enrichment cannot replace current app metadata with an older snapshot")
    func enrichmentPreservesAppVersion() async throws {
        let mock = MockCommandRunner()
        let (service, _) = makeService(mock: mock)
        let current = try decodeVersionFixture(bundleJSON: "\"158.0\"").toPackage()
        let stale = try decodeVersionFixture(bundleJSON: "\"157.0\"").toPackage()
        mock.setResult(for: ["info", "--cask", "--json=v2", "--", "firefox"], output: installedJSON(appVersion: "157.0"))

        let details = try #require(await service.fetchPackageDetail(for: current))

        #expect(details.appVersion == "158.0")
        #expect(current.enriched(with: details).appVersion == "158.0")
        #expect(current.enriched(with: stale).appVersion == "158.0")
        #expect(current.enriched(with: stale).version == "156.0.1")
    }

    private func installedJSON(appVersion: String) -> String {
        """
        {"formulae":[],"casks":[{"token":"firefox","version":"157.0","installed":"155.0",
        "auto_updates":true,"bundle_short_version":"\(appVersion)","artifacts":[{"app":["Firefox.app"]}]}]}
        """
    }
}

private func decodeVersionFixture(
    recorded: String = "156.0.1",
    latest: String = "157.0",
    bundleJSON: String? = "\"157.0\"",
    autoUpdatesJSON: String? = "true",
    appCount: Int = 1
) throws -> CaskJSON {
    let bundleField = bundleJSON.map { ",\"bundle_short_version\":\($0)" } ?? ""
    let autoUpdatesField = autoUpdatesJSON.map { ",\"auto_updates\":\($0)" } ?? ""
    let artifacts = Array(repeating: "{\"app\":[\"Firefox.app\"]}", count: appCount).joined(separator: ",")
    let json = """
    {"token":"firefox","installed":"\(recorded)","version":"\(latest)","bundle_version":"20261001000000",
    "artifacts":[\(artifacts)]\(bundleField)\(autoUpdatesField)}
    """
    return try JSONDecoder().decode(CaskJSON.self, from: Data(json.utf8))
}
