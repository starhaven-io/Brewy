import AppKit
import SwiftUI

struct BundleView: View {
    @Environment(BrewService.self)
    private var brewService
    @AppStorage("brewfilePath")
    private var brewfilePath = ""

    private var groupedEntries: [BrewBundleEntryType: [BrewBundleEntry]] {
        Dictionary(grouping: brewService.bundleEntries, by: \.type)
    }

    private var navigationSubtitle: String {
        guard brewService.brewfileURL != nil else { return "No Brewfile" }
        let count = brewService.bundleEntries.count
        return count == 1 ? "1 entry" : "\(count) entries"
    }

    var body: some View {
        List {
            if let brewfileURL = brewService.brewfileURL {
                BundleStatusSection(
                    brewfileURL: brewfileURL,
                    entryCount: brewService.bundleEntries.count,
                    status: brewService.bundleCheckStatus,
                    isLoading: brewService.isBundleLoading
                )

                if brewService.bundleEntries.isEmpty, !brewService.isBundleLoading {
                    Section {
                        ContentUnavailableView(
                            "No Bundle Entries",
                            systemImage: "doc.text",
                            description: Text("No formulae, casks, taps, or Mac App Store apps were found in this Brewfile.")
                        )
                    }
                } else {
                    ForEach(BrewBundleEntryType.allCases) { type in
                        if let entries = groupedEntries[type], !entries.isEmpty {
                            Section {
                                ForEach(entries) { entry in
                                    BundleEntryRow(entry: entry)
                                }
                            } header: {
                                Label(type.title, systemImage: type.systemImage)
                            }
                        }
                    }
                }
            } else {
                Section {
                    BundleEmptyState(
                        chooseBrewfile: chooseBrewfile,
                        createBrewfile: createBrewfileFromInstalled
                    )
                }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .navigationTitle("Bundle")
        .navigationSubtitle(navigationSubtitle)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Choose Brewfile", systemImage: "folder") {
                    chooseBrewfile()
                }
                .help("Choose a Brewfile")

                Button("Create from Installed Packages", systemImage: "square.and.arrow.down") {
                    createBrewfileFromInstalled()
                }
                .help("Create a Brewfile from installed packages")
                .disabled(brewService.isPerformingAction)

                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await brewService.refreshBundle() }
                }
                .help("Refresh bundle status")
                .disabled(brewService.isBundleLoading)
            }
        }
        .overlay {
            if brewService.isBundleLoading, brewService.bundleEntries.isEmpty, brewService.brewfileURL != nil {
                ProgressView("Loading bundle...")
            }
        }
        .task(id: brewfilePath) {
            await brewService.refreshBundle()
        }
        .refreshable {
            await brewService.refreshBundle()
        }
    }

    @MainActor
    private func chooseBrewfile() {
        guard let path = BrewfilePicker.choosePath() else { return }
        brewfilePath = path
    }

    @MainActor
    private func createBrewfileFromInstalled() {
        let panel = NSSavePanel()
        panel.title = "Create Brewfile"
        panel.prompt = "Create"
        panel.nameFieldStringValue = "Brewfile"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await brewService.dumpBundle(to: url) }
    }
}

// MARK: - Bundle Status

private struct BundleStatusSection: View {
    let brewfileURL: URL
    let entryCount: Int
    let status: BrewBundleCheckStatus
    let isLoading: Bool

    var body: some View {
        Section {
            HStack(spacing: 10) {
                BrewyStatusDot(color: statusColor, label: statusTitle)
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusTitle)
                        .font(.headline)
                    Text(statusSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isLoading || status == .checking {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            LabeledContent("Brewfile") {
                Text(brewfileURL.path)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }

            if case .unsatisfied(let missing) = status, !missing.isEmpty {
                ForEach(missing, id: \.self) { dependency in
                    LabeledContent("Missing") {
                        Text(dependency)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
        } header: {
            Label("Check", systemImage: "checkmark.seal")
        }
    }

    private var statusTitle: String {
        switch status {
        case .unknown: return "Not Checked"
        case .noBrewfile: return "No Brewfile"
        case .checking: return "Checking..."
        case .satisfied: return "Satisfied"
        case .unsatisfied: return "Missing Dependencies"
        case .failed: return "Check Failed"
        }
    }

    private var statusSubtitle: String {
        switch status {
        case .unknown:
            return "\(entryCount) entries loaded."
        case .noBrewfile:
            return "Choose or create a Brewfile."
        case .checking:
            return "Checking Brewfile dependencies."
        case .satisfied:
            return "All Brewfile dependencies are installed."
        case .unsatisfied(let missing):
            let count = missing.count
            return count == 1 ? "1 dependency is missing." : "\(count) dependencies are missing."
        case .failed(let message):
            return message
        }
    }

    private var statusColor: Color {
        switch status {
        case .satisfied: return .green
        case .unsatisfied: return .red
        case .failed: return .orange
        case .checking: return .blue
        case .unknown, .noBrewfile: return .secondary
        }
    }
}

// MARK: - Bundle Empty State

private struct BundleEmptyState: View {
    let chooseBrewfile: () -> Void
    let createBrewfile: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("No Brewfile", systemImage: "doc.text")
        } description: {
            Text("Brewy looks for Homebrew Bundle's global Brewfile locations, or you can choose one.")
        } actions: {
            HStack(spacing: 10) {
                Button("Choose Brewfile", systemImage: "folder") {
                    chooseBrewfile()
                }
                Button("Create from Installed Packages", systemImage: "square.and.arrow.down") {
                    createBrewfile()
                }
            }
        }
    }
}

// MARK: - Bundle Entry Row

private struct BundleEntryRow: View {
    let entry: BrewBundleEntry

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: entry.type.systemImage)
                .font(.title3)
                .foregroundStyle(entry.type.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.body)
                    .fontWeight(.medium)
                Text(entry.type.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            BundleEntryStatusBadge(status: entry.status)
        }
        .padding(.vertical, 2)
    }
}

private struct BundleEntryStatusBadge: View {
    let status: BrewBundleEntryStatus

    var body: some View {
        BrewyStatusBadge(title, systemImage: systemImage, color: color)
    }

    private var title: String {
        switch status {
        case .installed: "installed"
        case .missing: "missing"
        case .unknown: "unknown"
        }
    }

    private var systemImage: String {
        switch status {
        case .installed: "checkmark.circle.fill"
        case .missing: "exclamationmark.circle.fill"
        case .unknown: "questionmark.circle.fill"
        }
    }

    private var color: Color {
        switch status {
        case .installed: .green
        case .missing: .red
        case .unknown: .secondary
        }
    }
}

extension BrewBundleEntryType {
    fileprivate var tint: Color {
        switch self {
        case .formula: .green
        case .cask: .indigo
        case .tap: .teal
        case .mas: .pink
        }
    }
}
