@testable import Brewy
import Foundation
import Testing

@Suite("Package cache")
@MainActor
struct PackageCacheTests {
    @Test("Mac App Store fetch failures preserve a successful Homebrew refresh and its cache", arguments: [true, false])
    func masFailureStillCachesBrewInventory(failsList: Bool) async throws {
        let fixture = try CacheFixture()
        defer { fixture.remove() }
        let mock = MockCommandRunner()
        let service = BrewService(commandRunner: mock, masExecutablePath: "/usr/bin/true",
                                  packageCacheURL: fixture.url, packageCacheWritesEnabled: true)
        setupRefreshMock(mock)
        mock.setResult(for: ["list", "--json"], output: "", success: !failsList)
        if failsList {
            mock.setResult(for: ["list"], output: "", success: false)
        } else {
            mock.setResult(for: ["outdated"], output: "", success: false)
        }

        await service.refresh()

        #expect(service.isMasAvailable)
        #expect(service.lastError == nil)
        #expect(service.backgroundRefreshError == nil)
        #expect(FileManager.default.fileExists(atPath: fixture.url.path))
        let refreshed = try #require(service.lastUpdated)
        let cached = BrewService(commandRunner: mock, packageCacheURL: fixture.url)
        cached.loadFromCache()
        #expect(cached.lastUpdated == refreshed)
        #expect(cached.installedFormulae.map(\.name) == ["wget"])
    }

    @Test("A partial refresh preserves the last complete timestamp in memory and on disk")
    func partialRefreshPreservesFreshness() async throws {
        let fixture = try CacheFixture()
        defer { fixture.remove() }
        let mock = MockCommandRunner()
        let service = BrewService(commandRunner: mock, masExecutablePath: "/nonexistent/mas",
                                  packageCacheURL: fixture.url, packageCacheWritesEnabled: true)
        await service.refresh()
        #expect(service.lastUpdated == nil)
        #expect(!service.tapsLoaded)
        #expect(!FileManager.default.fileExists(atPath: fixture.url.path))

        setupRefreshMock(mock)
        await service.refresh()
        let successful = try #require(service.lastUpdated)
        #expect(service.tapsLoaded)
        mock.setResult(for: ["tap-info", "--json=v1", "--installed"], output: "Unavailable", success: false)
        mock.setResult(for: ["outdated", "--json=v2"], output: TestJSON.emptyOutdated)
        await service.refresh()
        #expect(service.lastUpdated == successful)
        #expect(!service.tapsLoaded)
        #expect(!service.installedTaps.isEmpty)
        #expect(service.outdatedPackages.isEmpty)
        let reader = BrewService(commandRunner: mock, packageCacheURL: fixture.url)
        reader.loadFromCache()
        #expect(reader.lastUpdated == successful)
        #expect(reader.outdatedPackages.isEmpty)
    }

    @Test("Qualified command name survives cache and old snapshots use the short name")
    func qualifiedNameCompatibility() async throws {
        let fixture = try CacheFixture()
        defer { fixture.remove() }
        let json = """
        {"formulae":[{"name":"foo","full_name":"other/tap/foo","versions":{"stable":"1.0"}}],"casks":[]}
        """
        let response = try JSONDecoder().decode(BrewInfoResponse.self, from: Data(json.utf8))
        let package = try #require(response.formulae?.first?.toPackage())
        let writer = BrewService(
            commandRunner: MockCommandRunner(), packageCacheURL: fixture.url,
            packageCacheWritesEnabled: true
        )
        writer.installedFormulae = [package]
        writer.lastUpdated = Date()
        await writer.saveToCache()

        let current = BrewService(commandRunner: MockCommandRunner(), packageCacheURL: fixture.url)
        current.loadFromCache()
        #expect(current.installedFormulae.first?.brewName == "other/tap/foo")
        #expect(current.installedFormulae.first?.id == "formula-foo")

        try fixture.mutateJSON { object in
            var formulae = try #require(object["formulae"] as? [[String: Any]])
            formulae[0].removeValue(forKey: "qualifiedName")
            object["formulae"] = formulae
        }
        let legacy = BrewService(commandRunner: MockCommandRunner(), packageCacheURL: fixture.url)
        legacy.loadFromCache()
        #expect(legacy.installedFormulae.first?.brewName == "foo")
        #expect(legacy.installedFormulae.first?.id == "formula-foo")
    }

    @Test("Package cache round-trips all package sources and derived state")
    func roundTrip() async throws {
        let fixture = try CacheFixture()
        defer { fixture.remove() }

        let formula = makePackage(name: "wget", pinned: true, dependencies: ["openssl@3"])
        let cask = try makeCaskVersionPackage(recordedVersion: "157.0", appVersion: "158.0")
        let mas = makePackage(name: "Xcode", source: .mas)
        let outdated = makePackage(
            name: "wget",
            isOutdated: true,
            installedVersion: "1.0",
            latestVersion: "2.0"
        )
        let tap = BrewTap(
            name: "homebrew/core",
            remote: "https://github.com/Homebrew/homebrew-core",
            isOfficial: true,
            formulaNames: ["wget"],
            caskTokens: []
        )
        let lastUpdated = Date(timeIntervalSince1970: 1_700_000_000)

        let writer = BrewService(
            commandRunner: MockCommandRunner(),
            packageCacheURL: fixture.url,
            packageCacheWritesEnabled: true
        )
        writer.installedFormulae = [formula]
        writer.installedCasks = [cask]
        writer.installedMasApps = [mas]
        writer.outdatedPackages = [outdated]
        writer.installedTaps = [tap]
        writer.lastUpdated = lastUpdated

        await writer.saveToCache()

        let reader = BrewService(commandRunner: MockCommandRunner(), packageCacheURL: fixture.url)
        reader.loadFromCache()

        #expect(reader.installedFormulae == [formula])
        #expect(reader.installedCasks == [cask])
        #expect(reader.installedCasks.first?.installedVersion == "157.0")
        #expect(reader.installedCasks.first?.appVersion == "158.0")
        #expect(reader.installedCasks.first?.repositoryURL == "https://github.com/mozilla/gecko-dev")
        #expect(reader.installedMasApps == [mas])
        #expect(reader.outdatedPackages == [outdated])
        #expect(reader.installedTaps == [tap])
        #expect(reader.tapsLoaded)
        #expect(reader.isMasAvailable)
        #expect(reader.lastUpdated == lastUpdated)
        #expect(reader.allInstalled.map(\.id) == [formula.id, cask.id, mas.id])
        #expect(reader.pinnedPackages.map(\.id) == [formula.id])
        #expect(reader.dependents(of: "openssl@3").map(\.id) == [formula.id])
    }

    @Test("Package cache tolerates snapshots written before MAS apps were stored")
    func loadsLegacySnapshotWithoutMasApps() async throws {
        let fixture = try CacheFixture()
        defer { fixture.remove() }

        let writer = BrewService(
            commandRunner: MockCommandRunner(),
            packageCacheURL: fixture.url,
            packageCacheWritesEnabled: true
        )
        writer.installedFormulae = [makePackage(name: "wget")]
        writer.lastUpdated = Date()
        await writer.saveToCache()
        try fixture.mutateJSON { $0.removeValue(forKey: "masApps") }

        let reader = BrewService(commandRunner: MockCommandRunner(), packageCacheURL: fixture.url)
        reader.loadFromCache()

        #expect(reader.installedFormulae.map(\.name) == ["wget"])
        #expect(reader.installedMasApps.isEmpty)
    }

    @Test("Package cache tolerates snapshots written before repository URLs were stored")
    func loadsLegacySnapshotWithoutRepositoryURL() async throws {
        let fixture = try CacheFixture()
        defer { fixture.remove() }

        let writer = BrewService(
            commandRunner: MockCommandRunner(),
            packageCacheURL: fixture.url,
            packageCacheWritesEnabled: true
        )
        writer.installedCasks = [makePackage(name: "firefox", source: .cask)]
        writer.lastUpdated = Date()
        await writer.saveToCache()
        try fixture.mutateJSON { object in
            guard var casks = object["casks"] as? [[String: Any]], !casks.isEmpty else { return }
            casks[0].removeValue(forKey: "repositoryURL")
            object["casks"] = casks
        }

        let reader = BrewService(commandRunner: MockCommandRunner(), packageCacheURL: fixture.url)
        reader.loadFromCache()

        #expect(reader.installedCasks.map(\.name) == ["firefox"])
        #expect(reader.installedCasks.first?.repositoryURL == nil)
    }

    @Test("Package cache tolerates snapshots written before app versions were stored")
    func loadsLegacySnapshotWithoutAppVersion() async throws {
        let fixture = try CacheFixture()
        defer { fixture.remove() }
        let writer = BrewService(commandRunner: MockCommandRunner(), packageCacheURL: fixture.url, packageCacheWritesEnabled: true)
        writer.installedCasks = [try makeCaskVersionPackage(recordedVersion: "156.0.1", appVersion: "157.0")]
        writer.lastUpdated = Date()
        await writer.saveToCache()
        try fixture.mutateJSON { object in
            var casks = try #require(object["casks"] as? [[String: Any]])
            casks[0].removeValue(forKey: "appVersion")
            object["casks"] = casks
        }

        let reader = BrewService(commandRunner: MockCommandRunner(), packageCacheURL: fixture.url)
        reader.loadFromCache()

        #expect(reader.installedCasks.first?.installedVersion == "156.0.1")
        #expect(reader.installedCasks.first?.appVersion == nil)
    }

    @Test("Package cache rejects and deletes an incompatible schema")
    func rejectsIncompatibleSchema() async throws {
        let fixture = try CacheFixture()
        defer { fixture.remove() }

        let writer = BrewService(
            commandRunner: MockCommandRunner(),
            packageCacheURL: fixture.url,
            packageCacheWritesEnabled: true
        )
        writer.installedFormulae = [makePackage(name: "wget")]
        writer.lastUpdated = Date()
        await writer.saveToCache()
        try fixture.mutateJSON { $0["schemaVersion"] = BrewService.cacheSchemaVersion + 1 }

        let reader = BrewService(
            commandRunner: MockCommandRunner(),
            packageCacheURL: fixture.url,
            packageCacheWritesEnabled: true
        )
        reader.loadFromCache()

        #expect(reader.allInstalled.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.url.path))
    }

    @Test("Package cache rejects and deletes corrupt data")
    func rejectsCorruptData() throws {
        let fixture = try CacheFixture()
        defer { fixture.remove() }
        try Data("not-json".utf8).write(to: fixture.url)

        let reader = BrewService(
            commandRunner: MockCommandRunner(),
            packageCacheURL: fixture.url,
            packageCacheWritesEnabled: true
        )
        reader.loadFromCache()

        #expect(reader.allInstalled.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.url.path))
    }

    @Test("Read-only package cache does not save data")
    func readOnlyCacheDoesNotSave() async throws {
        let fixture = try CacheFixture()
        defer { fixture.remove() }

        let service = BrewService(commandRunner: MockCommandRunner(), packageCacheURL: fixture.url)
        service.installedFormulae = [makePackage(name: "wget")]
        service.lastUpdated = Date()

        await service.saveToCache()

        #expect(!FileManager.default.fileExists(atPath: fixture.url.path))
    }

    @Test("Read-only package cache does not delete corrupt data")
    func readOnlyCacheDoesNotDeleteCorruptData() throws {
        let fixture = try CacheFixture()
        defer { fixture.remove() }
        try Data("not-json".utf8).write(to: fixture.url)

        let service = BrewService(commandRunner: MockCommandRunner(), packageCacheURL: fixture.url)
        service.loadFromCache()

        #expect(service.allInstalled.isEmpty)
        #expect(FileManager.default.fileExists(atPath: fixture.url.path))
    }
}

private func makeCaskVersionPackage(recordedVersion: String, appVersion: String) throws -> BrewPackage {
    let json = """
    {"token":"firefox","version":"157.0","installed":"\(recordedVersion)",
    "auto_updates":true,"bundle_short_version":"\(appVersion)","artifacts":[{"app":["Firefox.app"]}],
    "homepage":"https://github.com/mozilla/gecko-dev"}
    """
    return try JSONDecoder().decode(CaskJSON.self, from: Data(json.utf8)).toPackage()
}

private struct CacheFixture {
    let directory: URL
    let url: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("brewy-package-cache-\(UUID().uuidString)", isDirectory: true)
        url = directory.appendingPathComponent("packageCache.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func mutateJSON(_ mutation: (inout [String: Any]) throws -> Void) throws {
        let data = try Data(contentsOf: url)
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CacheFixtureError.invalidJSONObject
        }
        try mutation(&object)
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private enum CacheFixtureError: Error {
    case invalidJSONObject
}
