import SwiftUI

private let homebrewAnalyticsDocumentationURL = ExternalURLPolicy.url(
    from: "https://docs.brew.sh/Analytics"
)

enum AppTheme: String, CaseIterable, Identifiable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"

    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

struct SettingsView: View {
    @AppStorage("brewPath")
    private var brewPath = "/opt/homebrew/bin/brew"
    @AppStorage("brewfilePath")
    private var brewfilePath = ""
    @AppStorage("autoRefreshInterval")
    private var autoRefreshInterval = 0
    @AppStorage(CommandRunner.preventHomebrewAutoUpdateKey)
    private var preventHomebrewAutoUpdate = false
    @AppStorage("showCasksByDefault")
    private var showCasksByDefault = false
    @AppStorage("appTheme")
    private var appTheme = AppTheme.system.rawValue
    @AppStorage(AppVisibilitySettings.showMenuBarIconKey)
    private var showMenuBarIcon = true
    @AppStorage(AppVisibilitySettings.showDockIconKey)
    private var showDockIcon = true

    private var isBrewPathValid: Bool {
        FileManager.default.isExecutableFile(atPath: brewPath)
    }

    private var isBrewfilePathValid: Bool {
        brewfilePath.isEmpty || BrewfileDiscovery.resolve(overridePath: brewfilePath) != nil
    }

    var body: some View {
        Form {
            TextField("Homebrew Path:", text: $brewPath)
                .help("Path to the brew executable")
            if !brewPath.isEmpty, !isBrewPathValid {
                Text("No executable found at this path.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            brewfileOverrideSetting

            Picker("Auto-refresh:", selection: $autoRefreshInterval) {
                Text("Off").tag(0)
                Text("Every 5 minutes").tag(300)
                Text("Every 15 minutes").tag(900)
                Text("Every hour").tag(3_600)
            }

            Toggle("Prevent Homebrew auto-update", isOn: $preventHomebrewAutoUpdate)
                .help("Stops Homebrew from updating itself before installs and upgrades.")

            HomebrewAnalyticsSetting()

            Picker("Appearance:", selection: $appTheme) {
                ForEach(AppTheme.allCases) { theme in
                    Text(theme.rawValue).tag(theme.rawValue)
                }
            }

            appVisibilitySettings

            Toggle("Show Casks by default", isOn: $showCasksByDefault)
        }
        .formStyle(.grouped)
        .padding()
        .onChange(of: showDockIcon, initial: true) {
            AppVisibilitySettings.applyDockIconVisibility(showDockIcon)
        }
        .frame(width: 560, height: 560)
    }

    private var appVisibilitySettings: some View {
        Group {
            Toggle("Show Dock icon", isOn: $showDockIcon)
                .accessibilityIdentifier("show-dock-icon-toggle")
                .help("Shows Brewy in the Dock and opens its window at launch. At least one app icon must remain visible.")
                .disabled(!showMenuBarIcon)

            Toggle("Show menu bar icon", isOn: $showMenuBarIcon)
                .accessibilityIdentifier("show-menu-bar-icon-toggle")
                .help("Shows package status and quick actions. At least one app icon must remain visible.")
                .disabled(!showDockIcon)

            Text("Keep at least one icon visible so you can reopen Brewy.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var brewfileOverrideSetting: some View {
        Group {
            LabeledContent("Brewfile:") {
                HStack(spacing: 8) {
                    TextField("Auto-detect", text: $brewfilePath)
                        .textFieldStyle(.roundedBorder)
                    Button("Choose", systemImage: "folder") {
                        chooseBrewfile()
                    }
                    .help("Choose a Brewfile")
                    Button("Clear", systemImage: "xmark.circle") {
                        brewfilePath = ""
                    }
                    .help("Use auto-discovery")
                    .disabled(brewfilePath.isEmpty)
                }
            }
            if !isBrewfilePathValid {
                Text("No Brewfile found at this path.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    @MainActor
    private func chooseBrewfile() {
        guard let path = BrewfilePicker.choosePath() else { return }
        brewfilePath = path
    }
}

private struct HomebrewAnalyticsSetting: View {
    @Environment(BrewService.self)
    private var brewService
    @State private var requestedState: Bool?

    private var isEnabled: Binding<Bool> {
        Binding(
            get: { requestedState ?? (brewService.homebrewAnalyticsStatus == .enabled) },
            set: { enabled in requestStateChange(enabled) }
        )
    }

    private var statusDescription: String {
        switch brewService.homebrewAnalyticsStatus {
        case .unknown:
            brewService.isUpdatingHomebrewAnalytics ? "Checking…" : "Unavailable"
        case .enabled:
            "Enabled"
        case .disabled:
            "Disabled"
        }
    }

    var body: some View {
        Section("Homebrew Analytics") {
            if brewService.homebrewAnalyticsStatus != .unknown {
                Toggle("Share Homebrew analytics", isOn: isEnabled)
                    .accessibilityIdentifier("homebrew-analytics-toggle")
                    .help("Changes Homebrew's analytics setting.")
                    .disabled(brewService.isUpdatingHomebrewAnalytics)
            }

            LabeledContent("Status:") {
                HStack(spacing: 8) {
                    Text(statusDescription)
                    if brewService.isUpdatingHomebrewAnalytics {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityHidden(true)
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("homebrew-analytics-status")
            .accessibilityLabel("Homebrew analytics status: \(statusDescription)")

            Text("Homebrew uses aggregate usage data to help maintainers prioritize work. This changes Homebrew's existing analytics setting.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let error = brewService.homebrewAnalyticsError {
                HStack {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(error)
                .accessibilityIdentifier("homebrew-analytics-error")
            }

            if brewService.homebrewAnalyticsStatus == .unknown,
               !brewService.isUpdatingHomebrewAnalytics {
                Button("Retry", systemImage: "arrow.clockwise") {
                    Task { @MainActor in
                        await brewService.refreshHomebrewAnalyticsStatus()
                    }
                }
                .accessibilityIdentifier("homebrew-analytics-retry")
            }

            if let documentationURL = homebrewAnalyticsDocumentationURL {
                Link("Learn more about Homebrew analytics", destination: documentationURL)
            }
        }
        .task {
            await brewService.refreshHomebrewAnalyticsStatus()
        }
    }

    private func requestStateChange(_ enabled: Bool) {
        requestedState = enabled
        Task { @MainActor in
            await brewService.setHomebrewAnalyticsEnabled(enabled)
            requestedState = nil
        }
    }
}
