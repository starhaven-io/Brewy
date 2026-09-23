@testable import Brewy
import Foundation
import Testing

@Suite("BrewService Preferences")
@MainActor
struct BrewServicePreferencesTests {

    @Test("each service gets its own store instead of the app's standard defaults under tests")
    func settingsAreIsolatedUnderTests() {
        let first = BrewService()
        let second = BrewService()

        #expect(first.preferences !== UserDefaults.standard)
        first.customBrewfilePath = "/tmp/Brewfile"
        first.trustedBrewfileDigest = "digest"

        #expect(second.customBrewfilePath.isEmpty)
        #expect(second.trustedBrewfileDigest.isEmpty)
    }

    @Test("settings read and write an injected UserDefaults store")
    func settingsUseInjectedUserDefaults() throws {
        let suiteName = "io.linnane.brewy.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let service = BrewService(preferences: defaults)

        #expect(service.customBrewPath == "/opt/homebrew/bin/brew")
        #expect(service.customBrewfilePath.isEmpty)
        service.customBrewPath = "/usr/local/bin/brew"
        service.customBrewfilePath = "/tmp/Brewfile"
        service.trustedBrewfilePath = "/tmp/Brewfile"
        service.trustedBrewfileDigest = "digest"

        #expect(defaults.string(forKey: "brewPath") == "/usr/local/bin/brew")
        #expect(defaults.string(forKey: "brewfilePath") == "/tmp/Brewfile")
        #expect(defaults.string(forKey: "trustedBrewfilePath") == "/tmp/Brewfile")
        #expect(defaults.string(forKey: "trustedBrewfileDigest") == "digest")
    }
}
