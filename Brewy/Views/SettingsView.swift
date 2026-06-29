import SwiftUI

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
    @AppStorage("autoRefreshInterval")
    private var autoRefreshInterval = 0
    @AppStorage("showCasksByDefault")
    private var showCasksByDefault = false
    @AppStorage("appTheme")
    private var appTheme = AppTheme.system.rawValue
    @AppStorage("appIcon")
    private var appIcon = AppIconSelection.current.rawValue

    private var isBrewPathValid: Bool {
        FileManager.default.isExecutableFile(atPath: brewPath)
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

            Picker("Auto-refresh:", selection: $autoRefreshInterval) {
                Text("Off").tag(0)
                Text("Every 5 minutes").tag(300)
                Text("Every 15 minutes").tag(900)
                Text("Every hour").tag(3_600)
            }

            Picker("Appearance:", selection: $appTheme) {
                ForEach(AppTheme.allCases) { theme in
                    Text(theme.rawValue).tag(theme.rawValue)
                }
            }

            LabeledContent("App Icon:") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 12) {
                        ForEach(AppIconSelection.allCases) { icon in
                            AppIconOptionButton(
                                icon: icon,
                                isSelected: appIcon == icon.rawValue
                            ) {
                                appIcon = icon.rawValue
                            }
                        }
                    }

                    Text("Changes the running app's Dock icon. The Finder icon is unchanged.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Toggle("Show Casks by default", isOn: $showCasksByDefault)
        }
        .formStyle(.grouped)
        .padding()
        // Mirrors BrewyApp because the main-window handler does not fire when only the menu bar extra is alive.
        .onChange(of: appIcon, initial: true) {
            AppIconSelection.apply(rawValue: appIcon)
        }
        .frame(width: 500, height: 330)
    }
}

private struct AppIconOptionButton: View {
    let icon: AppIconSelection
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                AppIconPreviewTile(icon: icon)

                Text(icon.title)
                    .font(.caption)
                    .foregroundStyle(.primary)
            }
            .frame(width: 82, height: 86)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(
                        isSelected ? Color.accentColor : Color.secondary.opacity(0.28),
                        lineWidth: isSelected ? 2 : 1
                    )
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(icon.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct AppIconPreviewTile: View {
    let icon: AppIconSelection

    private var imageInset: CGFloat {
        switch icon {
        case .current: 4
        case .classic: 0
        }
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))

            Image(nsImage: icon.previewImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .padding(imageInset)
        }
        .frame(width: 54, height: 54)
        .clipShape(.rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
        }
    }
}
