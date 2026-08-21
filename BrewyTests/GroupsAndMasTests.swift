@testable import Brewy
import Foundation
import Testing

// MARK: - PackageGroup Model Tests

@Suite("PackageGroup Model")
struct PackageGroupTests {

    @Test("PackageGroup initializes with defaults")
    func defaultInitialization() {
        let group = PackageGroup(name: "My Group")
        #expect(group.name == "My Group")
        #expect(group.systemImage == "folder.fill")
        #expect(group.packageIDs.isEmpty)
    }

    @Test("PackageGroup initializes with custom values")
    func customInitialization() {
        let group = PackageGroup(
            name: "Dev Tools",
            systemImage: "wrench.fill",
            packageIDs: ["formula-git", "formula-curl"]
        )
        #expect(group.name == "Dev Tools")
        #expect(group.systemImage == "wrench.fill")
        #expect(group.packageIDs.count == 2)
    }

    @Test("PackageGroup equality is based on ID")
    func equalityById() {
        let id = UUID()
        let group1 = PackageGroup(id: id, name: "Group A")
        let group2 = PackageGroup(id: id, name: "Group B", systemImage: "star.fill")
        #expect(group1 == group2)
        #expect(group1.hashValue == group2.hashValue)
    }

    @Test("PackageGroups with different IDs are not equal")
    func inequalityByDifferentId() {
        let group1 = PackageGroup(name: "Group A")
        let group2 = PackageGroup(name: "Group A")
        #expect(group1 != group2)
    }

    @Test("PackageGroup encodes and decodes correctly")
    func encodeDecode() throws {
        let group = PackageGroup(
            name: "Server Tools",
            systemImage: "server.rack",
            packageIDs: ["formula-nginx", "formula-redis"]
        )
        let data = try JSONEncoder().encode(group)
        let decoded = try JSONDecoder().decode(PackageGroup.self, from: data)
        #expect(decoded.id == group.id)
        #expect(decoded.name == "Server Tools")
        #expect(decoded.systemImage == "server.rack")
        #expect(decoded.packageIDs == ["formula-nginx", "formula-redis"])
    }
}

// MARK: - BrewService Package Group Tests

@Suite("BrewService Package Groups")
@MainActor
struct BrewServicePackageGroupTests {

    @Test("createGroup adds a group")
    func createGroupAddsGroup() {
        let service = BrewService()
        service.createGroup(name: "Dev Tools", systemImage: "wrench.fill")

        #expect(service.packageGroups.count == 1)
        #expect(service.packageGroups[0].name == "Dev Tools")
        #expect(service.packageGroups[0].systemImage == "wrench.fill")
    }

    @Test("deleteGroup removes the group")
    func deleteGroupRemovesGroup() {
        let service = BrewService()
        service.createGroup(name: "Group A")
        service.createGroup(name: "Group B")
        let groupA = service.packageGroups[0]

        service.deleteGroup(groupA)

        #expect(service.packageGroups.count == 1)
        #expect(service.packageGroups[0].name == "Group B")
    }

    @Test("updateGroup modifies name and icon")
    func updateGroupModifies() {
        let service = BrewService()
        service.createGroup(name: "Old Name")
        let group = service.packageGroups[0]

        service.updateGroup(group, name: "New Name", systemImage: "star.fill")

        #expect(service.packageGroups[0].name == "New Name")
        #expect(service.packageGroups[0].systemImage == "star.fill")
    }

    @Test("addToGroup adds package ID")
    func addToGroupAddsPackageID() {
        let service = BrewService()
        service.createGroup(name: "Test")
        let group = service.packageGroups[0]

        service.addToGroup(group, packageID: "formula-wget")

        #expect(service.packageGroups[0].packageIDs == ["formula-wget"])
    }

    @Test("addToGroup prevents duplicates")
    func addToGroupPreventsDuplicates() {
        let service = BrewService()
        service.createGroup(name: "Test")
        let group = service.packageGroups[0]

        service.addToGroup(group, packageID: "formula-wget")
        service.addToGroup(group, packageID: "formula-wget")

        #expect(service.packageGroups[0].packageIDs.count == 1)
    }

    @Test("removeFromGroup removes package ID")
    func removeFromGroupRemovesPackageID() {
        let service = BrewService()
        service.createGroup(name: "Test")
        let group = service.packageGroups[0]
        service.addToGroup(group, packageID: "formula-wget")
        service.addToGroup(group, packageID: "formula-curl")

        service.removeFromGroup(service.packageGroups[0], packageID: "formula-wget")

        #expect(service.packageGroups[0].packageIDs == ["formula-curl"])
    }

    @Test("packages(in:) resolves package IDs to installed packages")
    func packagesInGroupResolvesIDs() {
        let service = BrewService()
        service.installedFormulae = [
            makePackage(name: "wget"),
            makePackage(name: "curl"),
            makePackage(name: "git")
        ]
        service.createGroup(name: "Test")
        let group = service.packageGroups[0]
        service.addToGroup(group, packageID: "formula-wget")
        service.addToGroup(group, packageID: "formula-git")

        let packages = service.packages(in: service.packageGroups[0])
        #expect(packages.count == 2)
        #expect(Set(packages.map(\.name)) == Set(["wget", "git"]))
    }

    @Test("packages(in:) ignores uninstalled package IDs")
    func packagesInGroupIgnoresUninstalled() {
        let service = BrewService()
        service.installedFormulae = [makePackage(name: "wget")]
        service.createGroup(name: "Test")
        let group = service.packageGroups[0]
        service.addToGroup(group, packageID: "formula-wget")
        service.addToGroup(group, packageID: "formula-removed")

        let packages = service.packages(in: service.packageGroups[0])
        #expect(packages.count == 1)
        #expect(packages[0].name == "wget")
    }

    @Test("packages(for: .groups) returns empty")
    func packagesForGroupsCategoryReturnsEmpty() {
        let service = BrewService()
        service.createGroup(name: "Test")
        #expect(service.packages(for: .groups).isEmpty)
    }
}

// MARK: - Mas Output Parsing Tests

@Suite("Mas Output Parsing")
struct MasOutputParsingTests {

    @Test("parseMasJSONList preserves application paths")
    func parseMasJSONList() throws {
        let output = """
        {"adamID":497799835,"bundleID":"com.apple.dt.Xcode","name":"Xcode","path":"/Applications/Xcode.app","version":"16.4"}
        {"adamID":0,"bundleID":"com.example.beta","name":"Beta App","path":"/Applications/Beta App.app","version":"2.0"}
        """

        let result = try #require(MasParser.parseJSONList(output))

        #expect(result.packages.map(\.id) == ["mas-497799835", "mas-0-Beta App"])
        #expect(result.applicationURLs["mas-497799835"]?.path == "/Applications/Xcode.app")
        #expect(result.applicationURLs["mas-0-Beta App"]?.path == "/Applications/Beta App.app")
    }

    @Test("parseMasJSONList tolerates missing Spotlight fields")
    func parseMasJSONListMissingFields() throws {
        let output = """
        {"adamID":497799835,"name":"Xcode","path":"/Applications/Xcode.app"}
        {"adamID":640199958,"name":"Developer","version":"10.6.5"}
        """

        let result = try #require(MasParser.parseJSONList(output))

        #expect(result.packages.map(\.id) == ["mas-497799835", "mas-640199958"])
        #expect(result.packages.map(\.version) == ["", "10.6.5"])
        #expect(result.applicationURLs["mas-497799835"]?.path == "/Applications/Xcode.app")
        #expect(result.applicationURLs["mas-640199958"] == nil)
    }

    @Test("parseMasJSONList preserves valid records beside malformed records")
    func parseMasJSONListPartialOutput() throws {
        let output = """
        {"adamID":497799835,"name":"Xcode","path":"/Applications/Xcode.app","version":"16.4"}
        not-json
        """

        let result = try #require(MasParser.parseJSONList(output))

        #expect(result.packages.map(\.id) == ["mas-497799835"])
    }

    @Test("parseMasJSONList rejects malformed output for legacy fallback")
    func parseMasJSONListMalformed() {
        #expect(MasParser.parseJSONList("497799835 Xcode (16.4)") == nil)
    }

    @Test("parseMasList parses standard output")
    func parseMasListStandard() {
        let output = """
        497799835 Xcode (15.4)
        640199958 Developer (10.6.5)
        899247664 TestFlight (3.5.2)
        """
        let packages = MasParser.parseList(output)
        #expect(packages.count == 3)
        #expect(packages[0].name == "Xcode")
        #expect(packages[0].version == "15.4")
        #expect(packages[0].id == "mas-497799835")
        #expect(packages[0].isMas == true)
        #expect(packages[0].isCask == false)
        #expect(packages[1].name == "Developer")
        #expect(packages[2].name == "TestFlight")
    }

    @Test("parseMasList handles empty output")
    func parseMasListEmpty() {
        let packages = MasParser.parseList("")
        #expect(packages.isEmpty)
    }

    @Test("parseMasList skips malformed lines")
    func parseMasListMalformed() {
        let output = """
        497799835 Xcode (15.4)
        not-a-number Something (1.0)
        899247664 TestFlight (3.5.2)
        """
        let packages = MasParser.parseList(output)
        #expect(packages.count == 2)
    }

    @Test("parseMasOutdated parses standard output")
    func parseMasOutdatedStandard() {
        let output = """
        497799835 Xcode (15.4 -> 16.0)
        640199958 Developer (10.6.5 -> 10.6.6)
        """
        let packages = MasParser.parseOutdated(output)
        #expect(packages.count == 2)
        #expect(packages[0].name == "Xcode")
        #expect(packages[0].isOutdated == true)
        #expect(packages[0].installedVersion == "15.4")
        #expect(packages[0].latestVersion == "16.0")
        #expect(packages[0].isMas == true)
        #expect(packages[1].installedVersion == "10.6.5")
        #expect(packages[1].latestVersion == "10.6.6")
    }

    @Test("parseMasOutdated handles empty output")
    func parseMasOutdatedEmpty() {
        let packages = MasParser.parseOutdated("")
        #expect(packages.isEmpty)
    }

    @Test("parseMasOutdated uses the same version when no arrow is present")
    func parseMasOutdatedWithoutArrow() {
        let output = "497799835 Xcode (16.0)\n"
        let packages = MasParser.parseOutdated(output)

        #expect(packages.count == 1)
        #expect(packages[0].installedVersion == "16.0")
        #expect(packages[0].latestVersion == "16.0")
        #expect(packages[0].version == "16.0")
    }

    @Test("parseMasList generates App Store homepage URLs")
    func parseMasListHomepage() {
        let output = "497799835 Xcode (15.4)\n"
        let packages = MasParser.parseList(output)
        #expect(packages[0].homepage == "https://apps.apple.com/app/id497799835")
    }

    @Test("parseMasList generates unique IDs for TestFlight apps with ID 0")
    func parseMasListTestFlightApps() {
        let output = """
        0 App Alpha (1.0)
        0 App Beta (2.0)
        497799835 Xcode (15.4)
        """
        let packages = MasParser.parseList(output)
        #expect(packages.count == 3)
        #expect(packages[0].id == "mas-0-App Alpha")
        #expect(packages[1].id == "mas-0-App Beta")
        #expect(packages[2].id == "mas-497799835")
        // TestFlight apps with ID 0 should not have an App Store URL
        #expect(packages[0].homepage.isEmpty)
        #expect(packages[1].homepage.isEmpty)
        // All IDs must be unique (no Dictionary(uniqueKeysWithValues:) crash)
        let ids = packages.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test("parseMasOutdated generates unique IDs for TestFlight apps with ID 0")
    func parseMasOutdatedTestFlightApps() {
        let output = """
        0 App Alpha (1.0 -> 1.1)
        0 App Beta (2.0 -> 2.1)
        """
        let packages = MasParser.parseOutdated(output)
        #expect(packages.count == 2)
        #expect(packages[0].id == "mas-0-App Alpha")
        #expect(packages[1].id == "mas-0-App Beta")
        #expect(packages[0].id != packages[1].id)
    }
}

@Suite("Mas Installed App Fetching")
@MainActor
struct MasInstalledAppFetchingTests {

    @Test("fetchInstalledMasApps prefers JSON output with application paths")
    func fetchInstalledMasAppsJSON() async throws {
        let mock = MockCommandRunner()
        let output = """
        {"adamID":497799835,"name":"Xcode","path":"/Applications/Xcode.app","version":"16.4"}
        """
        mock.setResult(for: ["list", "--json"], output: output)
        let service = BrewService(commandRunner: mock, masExecutablePath: "/usr/bin/true")

        let result = try #require(await service.fetchInstalledMasApps())

        #expect(result.packages.map(\.id) == ["mas-497799835"])
        #expect(result.applicationURLs["mas-497799835"]?.path == "/Applications/Xcode.app")
        #expect(mock.executedCommands == [["list", "--json"]])
        #expect(mock.executedExecutables.map(\.path) == ["/usr/bin/true"])
    }

    @Test("fetchInstalledMasApps falls back for older mas versions")
    func fetchInstalledMasAppsLegacyFallback() async throws {
        let mock = MockCommandRunner()
        mock.setResult(for: ["list", "--json"], output: "unknown option", success: false)
        mock.setResult(for: ["list"], output: "497799835 Xcode (15.4)")
        let service = BrewService(commandRunner: mock, masExecutablePath: "/usr/bin/true")

        let result = try #require(await service.fetchInstalledMasApps())

        #expect(result.packages.map(\.id) == ["mas-497799835"])
        #expect(result.applicationURLs.isEmpty)
        #expect(mock.executedCommands == [["list", "--json"], ["list"]])
        #expect(mock.executedExecutables.map(\.path) == ["/usr/bin/true", "/usr/bin/true"])
    }

    @Test("fetchInstalledMasApps parses JSON emitted by the fallback command")
    func fetchInstalledMasAppsJSONFallback() async throws {
        let mock = MockCommandRunner()
        mock.setResult(for: ["list", "--json"], output: "unknown option", success: false)
        mock.setResult(
            for: ["list"],
            output: #"{"adamID":497799835,"name":"Xcode","path":"/Applications/Xcode.app","version":"16.4"}"#
        )
        let service = BrewService(commandRunner: mock, masExecutablePath: "/usr/bin/true")

        let result = try #require(await service.fetchInstalledMasApps())

        #expect(result.packages.map(\.id) == ["mas-497799835"])
        #expect(result.applicationURLs["mas-497799835"]?.path == "/Applications/Xcode.app")
    }

    @Test("fetchInstalledMasApps treats empty standard output as an empty list")
    func fetchInstalledMasAppsEmptyStandardOutput() async throws {
        let mock = MockCommandRunner()
        mock.setResult(
            for: ["list", "--json"],
            result: CommandResult(
                output: "Warning: No installed apps found.",
                success: true,
                standardOutput: "",
                standardError: "Warning: No installed apps found."
            )
        )
        let service = BrewService(commandRunner: mock, masExecutablePath: "/usr/bin/true")

        let result = try #require(await service.fetchInstalledMasApps())

        #expect(result.packages.isEmpty)
        #expect(mock.executedCommands == [["list", "--json"]])
    }

    @Test("fetchInstalledMasApps re-resolves the executable when no override is set")
    func fetchInstalledMasAppsReresolvesExecutable() async throws {
        let mock = MockCommandRunner()
        let resolver = MasPathResolver(path: "/usr/bin/true")
        mock.setResult(for: ["list", "--json"], output: "")
        let service = BrewService(
            commandRunner: mock,
            masExecutablePathResolver: resolver.resolve
        )

        _ = try #require(await service.fetchInstalledMasApps())
        resolver.path = "/usr/bin/false"
        _ = try #require(await service.fetchInstalledMasApps())

        #expect(mock.executedExecutables.map(\.path) == ["/usr/bin/true", "/usr/bin/false"])
    }
}

private final class MasPathResolver: @unchecked Sendable {
    private let lock = NSLock()
    private var _path: String

    init(path: String) {
        _path = path
    }

    var path: String {
        get { lock.withLock { _path } }
        set { lock.withLock { _path = newValue } }
    }

    func resolve() -> String {
        path
    }
}
