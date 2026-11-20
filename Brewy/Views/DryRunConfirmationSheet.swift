import SwiftUI

struct DryRunConfirmationSheet: View {
    @Environment(\.dismiss)
    private var dismiss
    let title: String
    let message: String
    let confirmLabel: String
    let dryRunAction: @MainActor () async -> BrewCommandPreview
    let confirmAction: @MainActor (BrewCommandPreview) async -> Void

    @State private var preview: BrewCommandPreview?
    private var previewOutput: String { preview?.result.output ?? "" }
    private var previewSucceeded: Bool { preview?.result.success == true && preview?.result.cancelled == false }

    var body: some View {
        VStack(spacing: 16) {
            Label(title, systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if let path = preview?.executablePath {
                LabeledContent("Homebrew", value: path)
                    .font(.caption)
                    .textSelection(.enabled)
            }
            previewSection

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(confirmLabel, role: .destructive) {
                    guard let preview else { return }
                    dismiss()
                    Task { await confirmAction(preview) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!previewSucceeded)
            }
        }
        .padding(20)
        .frame(width: 480)
        .task {
            let result = await dryRunAction()
            guard !Task.isCancelled else { return }
            preview = result
        }
    }

    @ViewBuilder private var previewSection: some View {
        if preview == nil {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading preview\u{2026}")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 60)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
        } else if !previewSucceeded {
            VStack(alignment: .leading, spacing: 8) {
                Label("Preview failed", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                if !previewOutput.isEmpty {
                    Text(previewOutput)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.red.opacity(0.08), in: .rect(cornerRadius: 8))
        } else if previewOutput.isEmpty {
            Text("No specific files listed. The operation may still free up space.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(12)
                .frame(maxWidth: .infinity)
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
        } else {
            ScrollView {
                Text(previewOutput)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 300)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
        }
    }
}

extension DryRunConfirmationSheet {
    static func clearCache(
        brewService: BrewService,
        afterConfirm: @escaping @MainActor () async -> Void = {}
    ) -> DryRunConfirmationSheet {
        DryRunConfirmationSheet(
            title: "Clear Download Cache?",
            message: "The following cached downloads and old versions will be removed.",
            confirmLabel: "Clear Cache",
            dryRunAction: { await brewService.dryRunCleanup() },
            confirmAction: { preview in
                await brewService.purgeCache(preview)
                await afterConfirm()
            }
        )
    }
}
