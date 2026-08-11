import AppKit
import Foundation
import OSLog

private let logger = Logger(subsystem: "io.linnane.brewy", category: "AppVisibilitySettings")

enum AppVisibilitySettings {
    enum EntryPoint {
        case dock
        case menuBar
    }

    static let showDockIconKey = "showDockIcon"
    static let showMenuBarIconKey = "showMenuBarIcon"

    static func prepareDefaults(
        _ defaults: UserDefaults = .standard,
        repairsInvalidState: Bool = !BrewyRuntime.isUnitTesting
    ) {
        defaults.register(defaults: [
            showDockIconKey: true,
            showMenuBarIconKey: true
        ])

        let arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        guard repairsInvalidState,
              shouldRepairHiddenState(
                  showDockIcon: defaults.bool(forKey: showDockIconKey),
                  showMenuBarIcon: defaults.bool(forKey: showMenuBarIconKey),
                  argumentDomain: arguments
              ) else { return }
        repairHiddenState(defaults, restoring: .menuBar)
    }

    @discardableResult
    static func repairHiddenState(
        _ defaults: UserDefaults = .standard,
        restoring entryPoint: EntryPoint
    ) -> Bool {
        guard !defaults.bool(forKey: showDockIconKey),
              !defaults.bool(forKey: showMenuBarIconKey) else { return false }

        let key = switch entryPoint {
        case .dock: showDockIconKey
        case .menuBar: showMenuBarIconKey
        }
        defaults.set(true, forKey: key)
        return true
    }

    static func hasVisibilityArgumentOverrides(_ defaults: UserDefaults = .standard) -> Bool {
        // Argument-domain values outrank persisted defaults, so repairing under an override would
        // mutate the user's real preferences without changing the effective value for this launch.
        let arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        return hasVisibilityArgumentOverrides(in: arguments)
    }

    static func shouldRepairHiddenState(
        showDockIcon: Bool,
        showMenuBarIcon: Bool,
        argumentDomain: [String: Any]
    ) -> Bool {
        !hasVisibilityArgumentOverrides(in: argumentDomain) && !showDockIcon && !showMenuBarIcon
    }

    private static func hasVisibilityArgumentOverrides(in arguments: [String: Any]) -> Bool {
        arguments[showDockIconKey] != nil || arguments[showMenuBarIconKey] != nil
    }

    static func activationPolicy(showDockIcon: Bool) -> NSApplication.ActivationPolicy {
        showDockIcon ? .regular : .accessory
    }

    @MainActor
    static func applyDockIconVisibility(_ isVisible: Bool) {
        guard !BrewyRuntime.isUnitTesting else { return }

        let policy = activationPolicy(showDockIcon: isVisible)
        let application = NSApplication.shared
        guard application.activationPolicy() != policy else { return }
        guard application.setActivationPolicy(policy) else {
            logger.error("Failed to set application activation policy to \(String(describing: policy))")
            return
        }
        if application.windows.contains(where: \.isVisible) {
            application.activate()
        }
    }
}

@MainActor
final class BrewyApplicationDelegate: NSObject, NSApplicationDelegate {
    private var userDefaultsObserver: (any NSObjectProtocol)?

    func applicationWillFinishLaunching(_ notification: Notification) {
        AppVisibilitySettings.applyDockIconVisibility(
            UserDefaults.standard.bool(forKey: AppVisibilitySettings.showDockIconKey)
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !BrewyRuntime.isUnitTesting else { return }
        userDefaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                Self.repairVisibilityIfNeeded()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let userDefaultsObserver {
            NotificationCenter.default.removeObserver(userDefaultsObserver)
        }
    }

    private static func repairVisibilityIfNeeded() {
        let defaults = UserDefaults.standard
        guard !AppVisibilitySettings.hasVisibilityArgumentOverrides(defaults) else { return }
        AppVisibilitySettings.repairHiddenState(defaults, restoring: .dock)
        AppVisibilitySettings.applyDockIconVisibility(
            defaults.bool(forKey: AppVisibilitySettings.showDockIconKey)
        )
    }
}
