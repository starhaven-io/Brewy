import Foundation

extension CommandRunner {
    static let preventHomebrewAutoUpdateKey = "preventHomebrewAutoUpdate"

    /// Homebrew writes its auto-update report to standard output ahead of the command's own
    /// output. These verbs stream to the action overlay, where the report is readable; every
    /// other invocation is parsed, so the report would corrupt it.
    private static let autoUpdateStreamedVerbs: Set<String> = ["install", "upgrade", "tap"]

    static func preventsHomebrewAutoUpdate(userDefaults: UserDefaults = .standard) -> Bool {
        userDefaults.bool(forKey: preventHomebrewAutoUpdateKey)
    }

    static func shouldPreventHomebrewAutoUpdate(
        for arguments: [String],
        userDefaults: UserDefaults = .standard
    ) -> Bool {
        guard let verb = arguments.first, autoUpdateStreamedVerbs.contains(verb) else { return true }
        return preventsHomebrewAutoUpdate(userDefaults: userDefaults)
    }
}
