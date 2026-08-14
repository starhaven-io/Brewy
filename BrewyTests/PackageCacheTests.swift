@testable import Brewy
import Foundation
import Testing

@Suite("Package cache")
@MainActor
struct PackageCacheTests {
    @Test("Package cache round-trips all package sources and derived state")
    func roundTrip() async throws {
        let fixture = try CacheFixture()
        defer { fixture.remove() }

        let formula = makePackage(name: "wget", pinned: true, dependencies: ["openssl@3"])
        let cask = makePackage(name: "firefox", source: .cask)
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
        await writer.saveToCache()
        try fixture.mutateJSON { $0.removeValue(forKey: "masApps") }

        let reader = BrewService(commandRunner: MockCommandRunner(), packageCacheURL: fixture.url)
        reader.loadFromCache()

        #expect(reader.installedFormulae.map(\.name) == ["wget"])
        #expect(reader.installedMasApps.isEmpty)
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

private struct CacheFixture {
    let directory: URL
    let url: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("brewy-package-cache-\(UUID().uuidString)", isDirectory: true)
        url = directory.appendingPathComponent("packageCache.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func mutateJSON(_ mutation: (inout [String: Any]) -> Void) throws {
        let data = try Data(contentsOf: url)
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CacheFixtureError.invalidJSONObject
        }
        mutation(&object)
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private enum CacheFixtureError: Error {
    case invalidJSONObject
}
