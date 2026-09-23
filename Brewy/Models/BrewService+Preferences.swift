import Foundation

protocol PreferenceStore: AnyObject {
    func string(forKey defaultName: String) -> String?
    func set(_ value: Any?, forKey defaultName: String)
}

extension UserDefaults: PreferenceStore {}

#if DEBUG
final class InMemoryPreferenceStore: PreferenceStore {
    private var values: [String: String] = [:]

    func string(forKey defaultName: String) -> String? {
        values[defaultName]
    }

    func set(_ value: Any?, forKey defaultName: String) {
        values[defaultName] = value as? String
    }
}
#endif

extension BrewService {
    /// Tests run inside Brewy.app, whose standard defaults are the installed app's preferences.
    nonisolated static func runtimeDefaultPreferences() -> any PreferenceStore {
#if DEBUG
        if BrewyRuntime.isRunningTests {
            return InMemoryPreferenceStore()
        }
#endif
        return UserDefaults.standard
    }

    var customBrewPath: String {
        get { preferences.string(forKey: "brewPath") ?? "/opt/homebrew/bin/brew" }
        set { preferences.set(newValue, forKey: "brewPath") }
    }

    var customBrewfilePath: String {
        get { preferences.string(forKey: "brewfilePath") ?? "" }
        set { preferences.set(newValue, forKey: "brewfilePath") }
    }

    var trustedBrewfilePath: String {
        get { preferences.string(forKey: "trustedBrewfilePath") ?? "" }
        set { preferences.set(newValue, forKey: "trustedBrewfilePath") }
    }

    var trustedBrewfileDigest: String {
        get { preferences.string(forKey: "trustedBrewfileDigest") ?? "" }
        set { preferences.set(newValue, forKey: "trustedBrewfileDigest") }
    }
}
