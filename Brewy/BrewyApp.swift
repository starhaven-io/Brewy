import Combine
import Sparkle
import SwiftUI

@main
struct BrewyApp: App {
    @NSApplicationDelegateAdaptor(BrewyApplicationDelegate.self)
    private var applicationDelegate
    @State private var brewService = Self.makeBrewService()
    // HACK: there is a known color scheme bug in SwiftUI where passing `nil` to `.preferredColorScheme`
    // doesn't change the color of some elements:
    // https://stackoverflow.com/questions/76123702/preferredcolorschemenil-visual-bug-when-switching-to-system-light-dark-more
    // NSApplication.shared, not NSApp: this initializer can run before NSApp is set (seen on CI
    // test hosts), and .shared creates the instance instead of unwrapping nil.
    @State private var systemColorScheme = Self.colorScheme(for: NSApplication.shared.effectiveAppearance)
    private let updaterController: SPUStandardUpdaterController

    init() {
        AppVisibilitySettings.prepareDefaults()
        updaterController = SPUStandardUpdaterController(
            startingUpdater: !BrewyRuntime.isRunningTests,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    @AppStorage("appTheme")
    private var appTheme = AppTheme.system.rawValue
    @AppStorage("appIcon")
    private var appIcon = AppIconSelection.current.rawValue
    @AppStorage(AppVisibilitySettings.showMenuBarIconKey)
    private var showMenuBarIcon = true
    @AppStorage(AppVisibilitySettings.showDockIconKey)
    private var showDockIcon = true
    @AppStorage("autoRefreshInterval")
    private var autoRefreshInterval = 0

    private static func colorScheme(for appearance: NSAppearance) -> ColorScheme? {
        switch appearance.bestMatch(from: [.aqua, .darkAqua]) {
        case .aqua: .light
        case .darkAqua: .dark
        default: nil
        }
    }

    private static func makeBrewService() -> BrewService {
#if DEBUG
        if BrewyRuntime.isUITesting {
            return BrewService(commandRunner: UITestCommandRunner())
        }
#endif
        return BrewService()
    }

    private var preferredColorScheme: ColorScheme? {
        AppTheme(rawValue: appTheme)?.colorScheme
    }

    var body: some Scene {
        Window("Brewy", id: "main") {
            ContentView()
                .environment(brewService)
                .preferredColorScheme(preferredColorScheme ?? systemColorScheme)
                .onReceive(NSApplication.shared.publisher(for: \.effectiveAppearance)) { appearance in
                    systemColorScheme = Self.colorScheme(for: appearance)
                }
                .onChange(of: appIcon, initial: true) {
                    AppIconSelection.apply(rawValue: appIcon)
                }
                .onChange(of: showDockIcon, initial: true) {
                    AppVisibilitySettings.applyDockIconVisibility(showDockIcon)
                }
                .frame(minWidth: 920, minHeight: 620)
        }
        .windowStyle(.automatic)
        .windowToolbarStyle(.unified)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 960, height: 640)
        .defaultLaunchBehavior(showDockIcon ? .automatic : .suppressed)
        .restorationBehavior(showDockIcon ? .automatic : .disabled)
        .commands {
            ColumnSearchCommands()
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }
            CommandGroup(after: .newItem) {
                Button("Refresh Packages") {
                    Task { await brewService.refresh() }
                }
                .keyboardShortcut("r", modifiers: .command)

                Divider()

                UpgradeAllCommandButton(brewService: brewService)

                Button("Cleanup...") {
                    NotificationCenter.default.post(name: .showCleanupPreview, object: nil)
                }
            }
            CommandGroup(replacing: .help) {
                Button("What's New") {
                    NotificationCenter.default.post(name: .showWhatsNew, object: nil)
                }
            }
        }

        Settings {
            SettingsView()
                .environment(brewService)
        }

        MenuBarExtra(isInserted: $showMenuBarIcon) {
            MenuBarView()
                .environment(brewService)
        } label: {
            MenuBarStatusLabel(outdatedCount: brewService.outdatedPackages.count)
                .accessibilityIdentifier("brewy-menu-bar-icon")
                .task(id: autoRefreshInterval) {
                    brewService.startPackageUpdates(autoRefreshInterval: autoRefreshInterval)
                }
        }
    }
}

private struct ColumnSearchCommands: Commands {
    @FocusedValue(\.columnSearchFocus)
    private var columnSearchFocus

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Divider()

            Button("Find") {
                columnSearchFocus?.wrappedValue = true
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(columnSearchFocus == nil)
        }
    }
}

private struct UpgradeAllCommandButton: View {
    @Environment(\.openWindow)
    private var openWindow
    let brewService: BrewService

    var body: some View {
        Button("Upgrade All") {
            openWindow(id: "main")
            Task { await brewService.upgradeAll() }
        }
        .keyboardShortcut("u", modifiers: .command)
        .disabled(brewService.homebrewOutdatedPackages.isEmpty)
    }
}

// MARK: - Sparkle Updates

@MainActor
@Observable
private final class CheckForUpdatesViewModel {
    var canCheckForUpdates = false
    @ObservationIgnored private var cancellable: AnyCancellable?

    init(updater: SPUUpdater) {
        cancellable = updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                self?.canCheckForUpdates = value
            }
    }
}

private struct CheckForUpdatesView: View {
    @State private var viewModel: CheckForUpdatesViewModel
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        _viewModel = State(wrappedValue: CheckForUpdatesViewModel(updater: updater))
    }

    var body: some View {
        Button("Check for Updates…", action: updater.checkForUpdates)
            .disabled(!viewModel.canCheckForUpdates)
    }
}

// MARK: - Menu Bar View

private struct MenuBarStatusLabel: View {
    let outdatedCount: Int

    var body: some View {
        Group {
            if outdatedCount > 0 {
                Label("\(outdatedCount)", systemImage: "shippingbox.fill")
                    .labelStyle(.titleAndIcon)
            } else {
                Label("Brewy", systemImage: "shippingbox")
                    .labelStyle(.iconOnly)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        guard outdatedCount > 0 else { return "Brewy, all packages up to date" }
        return "Brewy, \(outdatedCount) package\(outdatedCount == 1 ? "" : "s") outdated"
    }
}

private struct MenuBarView: View {
    @Environment(BrewService.self)
    private var brewService
    @Environment(\.openWindow)
    private var openWindow

    var body: some View {
        let outdatedCount = brewService.outdatedPackages.count
        let homebrewOutdatedCount = brewService.homebrewOutdatedPackages.count

        if outdatedCount > 0 {
            Text("\(outdatedCount) package\(outdatedCount == 1 ? "" : "s") outdated")
            if homebrewOutdatedCount > 0 {
                Divider()
                Button("Upgrade Homebrew Packages") {
                    openMainWindow()
                    Task { await brewService.upgradeAll() }
                }
            }
        } else {
            Text("All packages up to date")
        }

        Divider()

        Button("Refresh") {
            Task { await brewService.refresh() }
        }
        .keyboardShortcut("r")

        SettingsLink()

        Divider()

        Button("Open Brewy") {
            openMainWindow()
        }
        .keyboardShortcut("o")

        Button("Quit Brewy") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private func openMainWindow() {
        NSApplication.shared.activate()
        openWindow(id: "main")
    }
}
