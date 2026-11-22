@testable import Brewy
import Foundation
import Testing

@Suite("CommandRunner Auto-Update")
struct CommandRunnerAutoUpdateTests {
    @Test("automatic Homebrew update prevention defaults off")
    func automaticHomebrewUpdatePreventionDefaultsOff() throws {
        let suiteName = "io.linnane.brewy.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(!CommandRunner.preventsHomebrewAutoUpdate(userDefaults: defaults))
    }

    @Test("automatic Homebrew update prevention sets Homebrew environment")
    func automaticHomebrewUpdatePreventionSetsEnvironment() {
        let env = CommandRunner.buildEnvironment(
            brewPath: "/opt/homebrew/bin/brew",
            preventHomebrewAutoUpdate: true,
            environment: [:]
        )

        #expect(env["HOMEBREW_NO_AUTO_UPDATE"] == "1")
    }

    @Test("automatic Homebrew update prevention leaves environment unchanged when disabled")
    func automaticHomebrewUpdatePreventionLeavesEnvironmentUnchangedWhenDisabled() {
        let env = CommandRunner.buildEnvironment(
            brewPath: "/opt/homebrew/bin/brew",
            preventHomebrewAutoUpdate: false,
            environment: [:]
        )

        #expect(env["HOMEBREW_NO_AUTO_UPDATE"] == nil)
        #expect(env["HOMEBREW_FORCE_API_AUTO_UPDATE"] == nil)
    }

    @Test("Forced Homebrew API refresh sets Homebrew environment")
    func forcedHomebrewAPIRefreshSetsEnvironment() {
        let env = CommandRunner.buildEnvironment(
            brewPath: "/opt/homebrew/bin/brew",
            preventHomebrewAutoUpdate: true,
            forceHomebrewAPIAutoUpdate: true,
            environment: [:]
        )

        #expect(env["HOMEBREW_NO_AUTO_UPDATE"] == "1")
        #expect(env["HOMEBREW_FORCE_API_AUTO_UPDATE"] == "1")
    }

    @Test("Outdated checks refresh Homebrew API data unless auto-update is prevented")
    func outdatedChecksRefreshHomebrewAPIData() throws {
        let suiteName = "io.linnane.brewy.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let arguments = ["outdated", "--json=v2"]

        #expect(CommandRunner.shouldPreventHomebrewAutoUpdate(for: arguments, userDefaults: defaults))
        #expect(CommandRunner.shouldForceHomebrewAPIAutoUpdate(for: arguments, userDefaults: defaults))
        defaults.set(true, forKey: CommandRunner.preventHomebrewAutoUpdateKey)
        #expect(!CommandRunner.shouldForceHomebrewAPIAutoUpdate(for: arguments, userDefaults: defaults))
    }

    @Test("Other Homebrew commands leave API refresh to Homebrew", arguments: [
        ["info", "--installed", "--json=v2"],
        ["tap-info", "--json=v1", "--installed"],
        ["update"],
        ["install", "--", "wget"],
        ["upgrade"],
        []
    ])
    func otherCommandsLeaveHomebrewAPIRefreshToHomebrew(arguments: [String]) throws {
        let suiteName = "io.linnane.brewy.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(!CommandRunner.shouldForceHomebrewAPIAutoUpdate(for: arguments, userDefaults: defaults))
    }

    @Test("Parsed Homebrew commands always prevent auto-update output", arguments: [
        ["outdated", "--json=v2"],
        ["info", "--installed", "--json=v2"],
        ["info", "--cask", "--json=v2", "--", "firefox"],
        ["tap-info", "--json=v1", "--installed"],
        ["search", "--formula", "--", "wget"],
        ["bundle", "list", "--formula", "--file=-"],
        ["bundle", "check", "--verbose", "--file=-"],
        ["services", "info", "--all", "--json"],
        ["services", "list", "--json"],
        ["vulns", "--json"],
        ["analytics", "state"],
        ["config"],
        ["--cache"],
        []
    ])
    func parsedCommandsAlwaysPreventAutomaticUpdate(arguments: [String]) throws {
        let suiteName = "io.linnane.brewy.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(CommandRunner.shouldPreventHomebrewAutoUpdate(for: arguments, userDefaults: defaults))
    }

    @Test("Streamed Homebrew commands follow the auto-update preference", arguments: [
        ["install", "--", "wget"],
        ["upgrade"],
        ["upgrade", "--cask", "--", "firefox"],
        ["tap", "--", "owner/tap"]
    ])
    func streamedCommandsFollowAutomaticUpdatePreference(arguments: [String]) throws {
        let suiteName = "io.linnane.brewy.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(!CommandRunner.shouldPreventHomebrewAutoUpdate(for: arguments, userDefaults: defaults))
        defaults.set(true, forKey: CommandRunner.preventHomebrewAutoUpdateKey)
        #expect(CommandRunner.shouldPreventHomebrewAutoUpdate(for: arguments, userDefaults: defaults))
    }
}
