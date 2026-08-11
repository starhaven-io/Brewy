import AppKit
@testable import Brewy
import Foundation
import Testing

@Suite("AppVisibilitySettings")
struct AppVisibilitySettingsTests {
    @Test("Maps Dock visibility to the matching activation policy")
    func activationPolicy() {
        #expect(AppVisibilitySettings.activationPolicy(showDockIcon: true) == .regular)
        #expect(AppVisibilitySettings.activationPolicy(showDockIcon: false) == .accessory)
    }

    @Test("Defaults keep both app entry points visible")
    func registersVisibleDefaults() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        AppVisibilitySettings.prepareDefaults(defaults, repairsInvalidState: true)

        #expect(defaults.bool(forKey: AppVisibilitySettings.showDockIconKey))
        #expect(defaults.bool(forKey: AppVisibilitySettings.showMenuBarIconKey))
    }

    @Test("Invalid hidden state restores the menu bar entry point")
    func restoresMenuBarEntryPoint() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(false, forKey: AppVisibilitySettings.showDockIconKey)
        defaults.set(false, forKey: AppVisibilitySettings.showMenuBarIconKey)

        AppVisibilitySettings.prepareDefaults(defaults, repairsInvalidState: true)

        #expect(!defaults.bool(forKey: AppVisibilitySettings.showDockIconKey))
        #expect(defaults.bool(forKey: AppVisibilitySettings.showMenuBarIconKey))
    }

    @Test("Runtime repair restores the Dock entry point")
    func restoresDockEntryPoint() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(false, forKey: AppVisibilitySettings.showDockIconKey)
        defaults.set(false, forKey: AppVisibilitySettings.showMenuBarIconKey)

        let repaired = AppVisibilitySettings.repairHiddenState(defaults, restoring: .dock)

        #expect(repaired)
        #expect(defaults.bool(forKey: AppVisibilitySettings.showDockIconKey))
        #expect(!defaults.bool(forKey: AppVisibilitySettings.showMenuBarIconKey))
    }

    @Test("Launch arguments suppress persistent visibility repair")
    func launchArgumentsSuppressRepair() {
        #expect(
            !AppVisibilitySettings.shouldRepairHiddenState(
                showDockIcon: false,
                showMenuBarIcon: false,
                argumentDomain: [AppVisibilitySettings.showDockIconKey: false]
            )
        )
        #expect(
            !AppVisibilitySettings.shouldRepairHiddenState(
                showDockIcon: false,
                showMenuBarIcon: false,
                argumentDomain: [AppVisibilitySettings.showMenuBarIconKey: false]
            )
        )
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "AppVisibilitySettingsTests-\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: suiteName)), suiteName)
    }
}
