import SwiftUI

struct MaintenanceView: View {
    @Environment(BrewService.self)
    private var brewService
    @State private var doctorOutput: String?
    @State private var isRunningDoctor = false
    @State private var isCalculatingCache = false
    @State private var cacheSizeBytes: Int64?
    @State private var brewConfig: BrewConfig?
    @State private var isLoadingConfig = true
    @State private var showRemoveOrphansConfirm = false
    @State private var showClearCacheConfirm = false
    @State private var doctorTask: Task<Void, Never>?

    var body: some View {
        Form {
            healthCheckSection
            orphansSection
            cacheSection
            homebrewUpdateSection
            whatsNewSection
        }
        .formStyle(.grouped)
        .navigationTitle("Maintenance")
        .sheet(isPresented: $showRemoveOrphansConfirm) {
            DryRunConfirmationSheet(
                title: "Remove Orphaned Packages?",
                message: "The following packages were installed as dependencies but are no longer needed.",
                confirmLabel: "Remove Orphans",
                dryRunAction: { await brewService.dryRunAutoremove() },
                confirmAction: { await brewService.removeOrphans() }
            )
        }
        .sheet(isPresented: $showClearCacheConfirm) {
            DryRunConfirmationSheet.clearCache(brewService: brewService) {
                await loadCacheSize()
            }
        }
        .task {
            async let cacheTask: () = loadCacheSize()
            async let configTask: () = loadConfig()
            _ = await (cacheTask, configTask)
        }
        .onDisappear {
            doctorTask?.cancel()
            doctorTask = nil
            isRunningDoctor = false
        }
    }

    // MARK: - Health Check

    private var healthCheckSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Health Check", systemImage: "stethoscope")
                        .font(.headline)
                    Spacer()
                    if isRunningDoctor {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Button("Run brew doctor") {
                        doctorTask?.cancel()
                        isRunningDoctor = true
                        doctorTask = Task {
                            let output = await brewService.doctor()
                            guard !Task.isCancelled else { return }
                            doctorOutput = output
                            isRunningDoctor = false
                            doctorTask = nil
                        }
                    }
                    .disabled(isRunningDoctor)
                }

                if let output = doctorOutput {
                    ConsoleOutput(text: output.isEmpty ? "Your system is ready to brew." : output, padding: 10)
                }
            }
        } footer: {
            Text("Checks your system for potential problems with Homebrew.")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Orphans

    private var orphansSection: some View {
        Section {
            HStack {
                Label("Orphaned Packages", systemImage: "shippingbox.and.arrow.backward")
                    .font(.headline)
                Spacer()
                if brewService.isPerformingAction {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("Remove Orphans") {
                    showRemoveOrphansConfirm = true
                }
                .disabled(brewService.isPerformingAction)
            }
        } footer: {
            Text("Removes packages that were installed as dependencies but are no longer needed.")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Cache

    private var cacheSection: some View {
        Section {
            HStack {
                Label("Download Cache", systemImage: "internaldrive")
                    .font(.headline)
                Spacer()

                if isCalculatingCache {
                    ProgressView()
                        .controlSize(.small)
                } else if let size = cacheSizeBytes {
                    Text(formattedSize(size))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .accessibilityIdentifier("maintenance-cache-size")
                }

                Button("Clear Cache") {
                    showClearCacheConfirm = true
                }
                .disabled(brewService.isPerformingAction)
            }
        } footer: {
            Text("Removes cached package downloads and old versions.")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Update

    private var homebrewUpdateSection: some View {
        Section {
            HStack {
                Label("Update Homebrew", systemImage: "arrow.triangle.2.circlepath")
                    .font(.headline)
                Spacer()
                if brewService.isPerformingAction {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("Update") {
                    Task {
                        await brewService.updateHomebrew()
                        await loadConfig()
                    }
                }
                .disabled(brewService.isPerformingAction)
            }

            configRow("Homebrew version", value: brewConfig?.version)
            configRow("Homebrew/brew last updated", value: brewConfig?.homebrewLastCommit)
            configRow("Homebrew/core last updated", value: brewConfig?.coreTapLastCommit)
            configRow("Homebrew/cask last updated", value: brewConfig?.coreCaskTapLastCommit)
        } footer: {
            Text("Fetches the newest version of Homebrew and all formulae, casks, and taps from GitHub.")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - What's New in Homebrew

    @ViewBuilder private var whatsNewSection: some View {
        if let result = brewService.lastUpdateResult, !result.isEmpty {
            Section {
                HStack(spacing: 8) {
                    Label("New since \(result.timestamp.formatted(.relative(presentation: .named)))", systemImage: "sparkles")
                        .font(.headline)
                    Spacer()
                    Text("\(result.totalCount)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                if !result.newFormulae.isEmpty {
                    NewItemsList(title: "New Formulae", items: result.newFormulae)
                }
                if !result.newCasks.isEmpty {
                    NewItemsList(title: "New Casks", items: result.newCasks)
                }
            } footer: {
                Text("Newly available packages from the last brew update.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Helpers

    private func loadCacheSize() async {
        isCalculatingCache = true
        let size = await brewService.cacheSize()
        guard !Task.isCancelled else {
            isCalculatingCache = false
            return
        }
        cacheSizeBytes = size
        isCalculatingCache = false
    }

    private func loadConfig() async {
        isLoadingConfig = true
        let config = await brewService.config()
        guard !Task.isCancelled else {
            isLoadingConfig = false
            return
        }
        brewConfig = config
        isLoadingConfig = false
    }

    private func configRow(_ label: String, value: String?) -> some View {
        LabeledContent(label) {
            if isLoadingConfig {
                ProgressView()
                    .controlSize(.small)
            } else {
                Text(value ?? "—")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }

    private static let sizeFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private func formattedSize(_ bytes: Int64) -> String {
        Self.sizeFormatter.string(fromByteCount: bytes)
    }
}

// MARK: - New Items List

private struct NewItemsList: View {
    let title: String
    let items: [BrewUpdateItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(items.count)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            ForEach(items) { item in
                NewItemRow(item: item)
            }
        }
    }
}

// MARK: - New Item Row

private struct NewItemRow: View {
    @Environment(BrewService.self)
    private var brewService
    let item: BrewUpdateItem

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.name).font(.body)
                    PackageSourceBadge(source: item.source)
                }
                if let desc = item.description {
                    Text(desc)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            if brewService.installedNames.contains(item.name) {
                Text("Installed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button {
                    Task { await brewService.install(package: item.asPlaceholderPackage()) }
                } label: {
                    Label("Install", systemImage: "arrow.down.circle.fill")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(brewService.isPerformingAction)
            }
        }
        .padding(.vertical, 2)
    }
}
