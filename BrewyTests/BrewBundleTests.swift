@testable import Brewy
import Foundation
import Testing

// MARK: - Brew Bundle Parsing

@Suite("Brew Bundle Parsing")
struct BrewBundleParsingTests {

    @Test("parseList trims lines for every bundle type")
    func parseListForEveryType() {
        for type in BrewBundleEntryType.allCases {
            let output = "  \(type.rawValue)-one  \n\n\(type.rawValue)-two\n"
            #expect(BrewBundleParser.parseList(output) == ["\(type.rawValue)-one", "\(type.rawValue)-two"])
        }
    }

    @Test("parseList handles empty output")
    func parseListEmpty() {
        #expect(BrewBundleParser.parseList("").isEmpty)
        #expect(BrewBundleParser.parseList("\n \n").isEmpty)
    }

    @Test("parseCheckResult treats exit zero as satisfied")
    func parseCheckSatisfied() {
        let status = BrewBundleParser.parseCheckResult(
            success: true,
            output: "The Brewfile's dependencies are satisfied.\n"
        )
        #expect(status == .satisfied)
    }

    @Test("parseCheckResult extracts verbose missing dependencies")
    func parseCheckUnsatisfied() {
        let output = """
        brew bundle can't satisfy your Brewfile's dependencies.
        → Cask firefox needs to be installed or updated.
        → Formula wget needs to be installed or updated.
        Satisfy missing dependencies with `brew bundle install`.
        """

        let status = BrewBundleParser.parseCheckResult(success: false, output: output)

        #expect(status == .unsatisfied([
            "Cask firefox",
            "Formula wget"
        ]))
    }

    @Test("parseCheckResult tolerates older installed-only suffixes")
    func parseCheckOlderInstalledSuffix() {
        let output = """
        * Formula jq needs to be installed.
        - Tap homebrew/cask needs to be installed.
        """

        let status = BrewBundleParser.parseCheckResult(success: false, output: output)

        #expect(status == .unsatisfied([
            "Formula jq",
            "Tap homebrew/cask"
        ]))
    }

    @Test("parseCheckResult treats non-missing failures as genuine failures")
    func parseCheckFailure() {
        let status = BrewBundleParser.parseCheckResult(
            success: false,
            output: "Error: No Brewfile found at /tmp/missing/Brewfile\n"
        )
        #expect(status == .failed("Error: No Brewfile found at /tmp/missing/Brewfile"))
    }
}

// MARK: - Brewfile Discovery

@Suite("Brewfile Discovery")
struct BrewfileDiscoveryTests {

    @Test("Settings override beats global candidates")
    func overrideBeatsGlobalCandidates() {
        let override = "/tmp/override/Brewfile"
        let xdg = "/tmp/xdg/homebrew/Brewfile"
        let homebrew = "/tmp/home/.homebrew/Brewfile"
        let home = URL(fileURLWithPath: "/tmp/home")
        let existing = Set([override, xdg, homebrew])

        let resolved = BrewfileDiscovery.resolve(
            overridePath: override,
            environment: ["XDG_CONFIG_HOME": "/tmp/xdg"],
            homeDirectory: home,
            fileExists: { existing.contains($0) }
        )

        #expect(resolved?.path == override)
    }

    @Test("Global discovery follows Homebrew candidate order")
    func globalCandidateOrder() {
        let xdg = "/tmp/xdg/homebrew/Brewfile"
        let dotHomebrew = "/tmp/home/.homebrew/Brewfile"
        let dotBrewfile = "/tmp/home/.Brewfile"
        let home = URL(fileURLWithPath: "/tmp/home")
        let existing = Set([dotHomebrew, dotBrewfile])

        let resolvedWithoutXDG = BrewfileDiscovery.resolve(
            overridePath: "",
            environment: [:],
            homeDirectory: home,
            fileExists: { existing.contains($0) }
        )
        #expect(resolvedWithoutXDG?.path == dotHomebrew)

        let resolvedWithXDG = BrewfileDiscovery.resolve(
            overridePath: "",
            environment: ["XDG_CONFIG_HOME": "/tmp/xdg"],
            homeDirectory: home,
            fileExists: { existing.union([xdg]).contains($0) }
        )
        #expect(resolvedWithXDG?.path == xdg)
    }

    @Test("No Brewfile found resolves nil")
    func noBrewfileFound() {
        let resolved = BrewfileDiscovery.resolve(
            overridePath: "",
            environment: [:],
            homeDirectory: URL(fileURLWithPath: "/tmp/home"),
            fileExists: { _ in false }
        )
        #expect(resolved == nil)
    }
}

// MARK: - BrewService Bundle

@Suite("BrewService Bundle")
@MainActor
struct BrewServiceBundleTests {

    @Test("fetchBundleEntries lists typed entries and marks installed status")
    func fetchBundleEntries() async throws {
        let brewfile = try Self.makeBrewfile()
        let mock = MockCommandRunner()
        let (service, _) = makeService(mock: mock)
        service.customBrewfilePath = brewfile.path
        service.installedFormulae = [makePackage(name: "wget")]
        service.installedCasks = [makePackage(name: "firefox", source: .cask)]
        service.installedTaps = [
            BrewTap(name: "homebrew/core", remote: "", isOfficial: true, formulaNames: [], caskTokens: [])
        ]
        service.isMasAvailable = false

        #expect(service.trustBrewfile(at: brewfile))
        Self.setBundleListResults(mock, path: brewfile.path)

        await service.fetchBundleEntries()

        #expect(service.bundleEntries.count == 6)
        #expect(service.bundleEntries.first { $0.name == "wget" }?.status == .installed)
        #expect(service.bundleEntries.first { $0.name == "curl" }?.status == .missing)
        #expect(service.bundleEntries.first { $0.name == "firefox" }?.status == .installed)
        #expect(service.bundleEntries.first { $0.name == "homebrew/core" }?.status == .installed)
        #expect(service.bundleEntries.first { $0.type == .mas }?.status == .unknown)
    }

    @Test("fetchBundleEntries marks mas entries installed by name")
    func fetchBundleEntriesMatchesMasByName() async throws {
        let brewfile = try Self.makeBrewfile()
        let mock = MockCommandRunner()
        let (service, _) = makeService(mock: mock)
        service.customBrewfilePath = brewfile.path
        service.isMasAvailable = true
        service.installedMasApps = [makePackage(name: "Xcode", source: .mas)]

        #expect(service.trustBrewfile(at: brewfile))
        Self.setBundleListResults(mock, path: brewfile.path)

        await service.fetchBundleEntries()

        #expect(service.bundleEntries.first { $0.type == .mas && $0.name == "Xcode" }?.status == .installed)
    }

    @Test("updateBundleEntryStatuses recomputes entries after installed packages load")
    func updateBundleEntryStatusesRecomputesAfterInstalledPackagesLoad() {
        let (service, _) = makeService(mock: MockCommandRunner())
        service.bundleEntries = [
            BrewBundleEntry(type: .formula, name: "wget", status: .missing),
            BrewBundleEntry(type: .cask, name: "firefox", status: .missing),
            BrewBundleEntry(type: .tap, name: "homebrew/core", status: .missing),
            BrewBundleEntry(type: .mas, name: "Xcode", status: .unknown)
        ]
        service.installedFormulae = [makePackage(name: "wget")]
        service.installedCasks = [makePackage(name: "firefox", source: .cask)]
        service.installedTaps = [
            BrewTap(name: "homebrew/core", remote: "", isOfficial: true, formulaNames: [], caskTokens: [])
        ]
        service.isMasAvailable = true
        service.installedMasApps = [makePackage(name: "Xcode", source: .mas)]

        service.updateBundleEntryStatuses()

        #expect(service.bundleEntries.allSatisfy { $0.status == .installed })
    }

    @Test("checkBundle reports satisfied without history")
    func checkBundleSatisfied() async throws {
        let brewfile = try Self.makeBrewfile()
        let mock = MockCommandRunner()
        let (service, _) = makeService(mock: mock)
        service.customBrewfilePath = brewfile.path
        #expect(service.trustBrewfile(at: brewfile))
        mock.setResult(
            for: ["bundle", "check", "--verbose", "--file=-"],
            output: "The Brewfile's dependencies are satisfied.\n"
        )

        await service.checkBundle()

        #expect(service.bundleCheckStatus == .satisfied)
        #expect(service.lastError == nil)
        #expect(service.actionHistory.isEmpty)
    }

    @Test("checkBundle treats unsatisfied dependencies as state")
    func checkBundleUnsatisfied() async throws {
        let brewfile = try Self.makeBrewfile()
        let mock = MockCommandRunner()
        let (service, _) = makeService(mock: mock)
        service.customBrewfilePath = brewfile.path
        #expect(service.trustBrewfile(at: brewfile))
        mock.setResult(
            for: ["bundle", "check", "--verbose", "--file=-"],
            output: """
            brew bundle can't satisfy your Brewfile's dependencies.
            → Cask firefox needs to be installed or updated.
            → Formula wget needs to be installed or updated.
            Satisfy missing dependencies with `brew bundle install`.
            """,
            success: false
        )

        await service.checkBundle()

        #expect(service.bundleCheckStatus == .unsatisfied(["Cask firefox", "Formula wget"]))
        #expect(service.lastError == nil)
        #expect(service.actionHistory.isEmpty)
    }

    @Test("checkBundle surfaces genuine failures")
    func checkBundleFailure() async throws {
        let brewfile = try Self.makeBrewfile()
        let mock = MockCommandRunner()
        let (service, _) = makeService(mock: mock)
        service.customBrewfilePath = brewfile.path
        #expect(service.trustBrewfile(at: brewfile))
        mock.setResult(
            for: ["bundle", "check", "--verbose", "--file=-"],
            output: "Error: Permission denied @ rb_sysopen - \(brewfile.path)\n",
            success: false
        )

        await service.checkBundle()

        if case .failed(let message) = service.bundleCheckStatus {
            #expect(message.contains("Permission denied"))
        } else {
            Issue.record("Expected bundle check failure")
        }
        #expect(service.lastError != nil)
    }

    @Test("no Brewfile yields empty state without error")
    func noBrewfileFound() async {
        let mock = MockCommandRunner()
        let (service, _) = makeService(mock: mock)
        service.customBrewfilePath = "/tmp/brewy-missing-\(UUID().uuidString)/Brewfile"

        await service.fetchBundleEntries()

        #expect(service.brewfileURL == nil)
        #expect(service.bundleEntries.isEmpty)
        #expect(service.bundleCheckStatus == .noBrewfile)
        #expect(service.lastError == nil)
        #expect(mock.executedCommands.isEmpty)
    }

    @Test("refreshBundle requires trust before executing Brewfile commands")
    func refreshBundleRequiresTrust() async throws {
        let brewfile = try Self.makeBrewfile()
        let mock = MockCommandRunner()
        let (service, _) = makeService(mock: mock)
        service.customBrewfilePath = brewfile.path
        Self.setBundleListResults(mock, path: brewfile.path)
        mock.setResult(
            for: ["bundle", "check", "--verbose", "--file=-"],
            output: "The Brewfile's dependencies are satisfied.\n"
        )

        await service.refreshBundle()

        #expect(service.brewfileURL?.path == brewfile.path)
        #expect(service.bundleEntries.isEmpty)
        #expect(service.bundleCheckStatus == .untrusted)
        #expect(mock.executedCommands.isEmpty)
    }

    @Test("trustCurrentBrewfileAndRefresh executes trusted Brewfile commands")
    func trustCurrentBrewfileAndRefreshExecutesCommands() async throws {
        let brewfile = try Self.makeBrewfile()
        let mock = MockCommandRunner()
        let (service, _) = makeService(mock: mock)
        service.customBrewfilePath = brewfile.path
        Self.setEmptyBundleListResults(mock, path: brewfile.path)
        mock.setResult(
            for: ["bundle", "check", "--verbose", "--file=-"],
            output: "The Brewfile's dependencies are satisfied.\n"
        )

        await service.trustCurrentBrewfileAndRefresh()

        #expect(service.trustedBrewfilePath == brewfile.path)
        #expect(service.trustedBrewfileDigest.isEmpty == false)
        #expect(service.bundleCheckStatus == .satisfied)
        #expect(mock.executedCommands.count == 5)
    }

    @Test("refreshBundle stops when listing fails")
    func refreshBundleStopsWhenListingFails() async throws {
        let brewfile = try Self.makeBrewfile()
        let mock = MockCommandRunner()
        let (service, _) = makeService(mock: mock)
        service.customBrewfilePath = brewfile.path
        #expect(service.trustBrewfile(at: brewfile))
        mock.setResult(
            for: ["bundle", "list", "--formula", "--file=-"],
            output: "Error: Permission denied @ rb_sysopen - \(brewfile.path)\n",
            success: false
        )
        mock.setResult(
            for: ["bundle", "check", "--verbose", "--file=-"],
            output: "The Brewfile's dependencies are satisfied.\n"
        )

        await service.refreshBundle()

        #expect(mock.executedCommands == [["bundle", "list", "--formula", "--file=-"]])
        if case .failed(let message) = service.bundleCheckStatus {
            #expect(message.contains("Permission denied"))
        } else {
            Issue.record("Expected bundle list failure")
        }
    }

    @Test("refreshBundle commands always include explicit file")
    func commandsIncludeExplicitFile() async throws {
        let brewfile = try Self.makeBrewfile()
        let mock = MockCommandRunner()
        let (service, _) = makeService(mock: mock)
        service.customBrewfilePath = brewfile.path
        #expect(service.trustBrewfile(at: brewfile))
        Self.setBundleListResults(mock, path: brewfile.path)
        mock.setResult(
            for: ["bundle", "check", "--verbose", "--file=-"],
            output: "The Brewfile's dependencies are satisfied.\n"
        )

        await service.refreshBundle()

        #expect(mock.executedCommands.count == 5)
        for command in mock.executedCommands {
            #expect(command.last == "--file=-")
        }
        #expect(mock.standardInputs.count == 5)
        #expect(mock.standardInputs.allSatisfy { $0.data == Data() })
    }

    @Test("dumpBundle writes through a private generated file")
    func dumpBundleForcesOverwrite() async throws {
        let brewfile = try Self.makeBrewfile()
        let mock = MockCommandRunner()
        let (service, _) = makeService(mock: mock)

        let result = await service.dumpBundle(to: brewfile)

        #expect(result.success == false)
        let command = try #require(mock.executedCommands.first)
        #expect(Array(command.prefix(4)) == ["bundle", "dump", "--force", "--file"])
        #expect(command.count == 5)
        #expect(command.last != "-")
        #expect(command.last != brewfile.path)
        #expect(service.lastError != nil)
        #expect(service.actionHistory.count == 1)
        #expect(service.actionHistory[0].status == .failure)
    }

    @Test("dumpBundle success adopts the path and refreshes")
    func dumpBundleSuccessAdoptsPathAndRefreshes() async throws {
        let brewfile = try Self.makeBrewfile()
        let mock = MockCommandRunner()
        let (service, _) = makeService(mock: mock)
        let generatedData = Data("brew \"wget\"\n".utf8)
        mock.setCommandHandler { arguments in
            guard Array(arguments.prefix(4)) == ["bundle", "dump", "--force", "--file"],
                  let path = arguments.last else { return nil }
            do {
                try generatedData.write(to: URL(fileURLWithPath: path))
                return CommandResult(output: "Auto-updated Homebrew!\n", success: true)
            } catch {
                return CommandResult(output: error.localizedDescription, success: false)
            }
        }
        Self.setEmptyBundleListResults(mock, path: brewfile.path)
        mock.setResult(
            for: ["bundle", "check", "--verbose", "--file=-"],
            output: "The Brewfile's dependencies are satisfied.\n"
        )

        let result = await service.dumpBundle(to: brewfile)

        #expect(result.success)
        #expect(service.customBrewfilePath == brewfile.path)
        #expect(service.bundleCheckStatus == .satisfied)
        #expect(service.actionHistory.first?.status == .success)
        #expect(mock.executedCommands.last == ["bundle", "check", "--verbose", "--file=-"])
        #expect(try String(contentsOf: brewfile, encoding: .utf8) == "brew \"wget\"\n")
        #expect(service.brewfileSnapshot?.data == generatedData)
    }

    @Test("existing empty Brewfile refreshes to satisfied empty state")
    func existingEmptyBrewfile() async throws {
        let brewfile = try Self.makeBrewfile()
        let mock = MockCommandRunner()
        let (service, _) = makeService(mock: mock)
        service.customBrewfilePath = brewfile.path
        #expect(service.trustBrewfile(at: brewfile))
        Self.setEmptyBundleListResults(mock, path: brewfile.path)
        mock.setResult(
            for: ["bundle", "check", "--verbose", "--file=-"],
            output: "The Brewfile's dependencies are satisfied.\n"
        )

        await service.refreshBundle()

        #expect(service.brewfileURL?.path == brewfile.path)
        #expect(service.bundleEntries.isEmpty)
        #expect(service.bundleEntryCount == 0)
        #expect(service.bundleCheckStatus == .satisfied)
    }

    private static func setBundleListResults(_ mock: MockCommandRunner, path _: String) {
        mock.setResult(for: ["bundle", "list", "--formula", "--file=-"], output: "wget\ncurl\n")
        mock.setResult(for: ["bundle", "list", "--cask", "--file=-"], output: "firefox\n")
        mock.setResult(for: ["bundle", "list", "--tap", "--file=-"], output: "homebrew/core\nhomebrew/cask\n")
        mock.setResult(for: ["bundle", "list", "--mas", "--file=-"], output: "Xcode\n")
    }

    private static func setEmptyBundleListResults(_ mock: MockCommandRunner, path _: String) {
        mock.setResult(for: ["bundle", "list", "--formula", "--file=-"], output: "")
        mock.setResult(for: ["bundle", "list", "--cask", "--file=-"], output: "")
        mock.setResult(for: ["bundle", "list", "--tap", "--file=-"], output: "")
        mock.setResult(for: ["bundle", "list", "--mas", "--file=-"], output: "")
    }

    private static func makeBrewfile(contents: String = "") throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrewyBundleTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let brewfile = directory.appendingPathComponent("Brewfile")
        try contents.write(to: brewfile, atomically: true, encoding: .utf8)
        return brewfile
    }
}
