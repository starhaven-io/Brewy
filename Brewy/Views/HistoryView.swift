import SwiftUI

struct HistoryView: View {
    @Environment(BrewService.self)
    private var brewService
    @Binding var selectedEntry: ActionHistoryEntry?

    var body: some View {
        List(selection: $selectedEntry) {
            if brewService.actionHistory.isEmpty {
                ContentUnavailableView(
                    "No History",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Actions you perform will appear here.")
                )
            } else {
                ForEach(brewService.actionHistory) { entry in
                    HistoryRow(entry: entry)
                        .tag(entry)
                }
            }
        }
        .navigationTitle("History")
        .navigationSubtitle("\(brewService.actionHistory.count) actions")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Clear History", systemImage: "trash") {
                    selectedEntry = nil
                    brewService.clearHistory()
                }
                .disabled(brewService.actionHistory.isEmpty)
                .help("Clear all history")
            }
        }
    }
}

// MARK: - History Row

private struct HistoryRow: View {
    let entry: ActionHistoryEntry

    var body: some View {
        HStack(spacing: 10) {
            BrewyStatusDot(
                color: entry.status == .success ? .green : .red,
                label: entry.status == .success ? "Succeeded" : "Failed"
            )
            VStack(alignment: .leading, spacing: 2) {
                if let name = entry.packageName {
                    HStack(spacing: 6) {
                        Text(name).fontWeight(.medium)
                        Text(entry.command)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(entry.command).fontWeight(.medium)
                }
                Text(entry.timestamp, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }
}

// MARK: - History Detail View

struct HistoryDetailView: View {
    @Environment(BrewService.self)
    private var brewService
    let entry: ActionHistoryEntry
    @State private var showRetryConfirmation = false

    var body: some View {
        Form {
            commandSection
            outputSection
            if entry.isRetryable {
                retrySection
            }
        }
        .formStyle(.grouped)
        .navigationTitle(entry.packageName ?? entry.command)
        .overlay {
            if brewService.isPerformingAction {
                ActionOverlay(output: brewService.actionOutput)
            }
        }
        .confirmationDialog("Retry Command?", isPresented: $showRetryConfirmation) {
            Button("Retry", role: .destructive) {
                Task { await brewService.retryAction(entry) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will re-run \(entry.displayCommand).")
        }
    }

    // MARK: - Sections

    private var commandSection: some View {
        Section {
            LabeledContent("Command") {
                Text(entry.displayCommand)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            LabeledContent("Status") {
                HStack(spacing: 6) {
                    BrewyStatusDot(
                        color: entry.status == .success ? .green : .red,
                        label: entry.status == .success ? "Succeeded" : "Failed"
                    )
                    .accessibilityHidden(true)
                    Text(entry.status == .success ? "Success" : "Failed")
                        .foregroundStyle(entry.status == .success ? .green : .red)
                }
            }
            LabeledContent("Time") {
                Text(entry.timestamp, format: .dateTime)
                    .foregroundStyle(.secondary)
            }
            if let name = entry.packageName {
                LabeledContent("Package") {
                    Text(name).foregroundStyle(.secondary)
                }
            }
            if let source = entry.packageSource {
                LabeledContent("Type") {
                    Text(source == .cask ? "Cask" : source == .mas ? "Mac App Store" : "Formula")
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Label("Action Info", systemImage: "info.circle")
        }
    }

    private var outputSection: some View {
        Section {
            if entry.output.isEmpty {
                Text("No output")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            } else {
                ConsoleOutput(text: entry.output, padding: 8)
            }
        } header: {
            Label("Output", systemImage: "terminal")
        }
    }

    private var retrySection: some View {
        Section {
            Button("Retry", systemImage: "arrow.clockwise") {
                if entry.isMutatingCommand {
                    showRetryConfirmation = true
                } else {
                    Task { await brewService.retryAction(entry) }
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.brewyAccent)
            .disabled(brewService.isPerformingAction)
        } footer: {
            Text("Re-runs the same command: \(entry.displayCommand)")
        }
    }
}
