import SwiftUI

struct BrewfileReviewSheet: View {
    @Environment(BrewService.self)
    private var brewService
    @Environment(\.dismiss)
    private var dismiss
    let review: BrewfileReview
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Review Brewfile")
                .font(.title2.bold())
            Text("Homebrew runs this file as Ruby. Review its contents before trusting it.")
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: review.snapshot.sourcePath)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                Spacer()
                Text("^[\(review.lineCount) line](inflect: true) · ^[\(review.snapshot.data.count) byte](inflect: true)")
                    .font(.callout)
                    .layoutPriority(1)
            }
            .foregroundStyle(.secondary)
            if review.showsBytes {
                Text("Showing the exact file bytes in hexadecimal.")
                    .font(.callout)
            }
            ScrollView(.vertical) {
                Text(verbatim: review.contents)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(.background.secondary, in: .rect(cornerRadius: 6))
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.callout)
            }
            HStack {
                Spacer()
                Button(failure == nil ? "Cancel" : "Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Trust and Refresh") {
                    do {
                        try brewService.trustReviewedBrewfile(review.snapshot)
                        dismiss()
                        Task { await brewService.refreshBundle() }
                    } catch {
                        failure = error.localizedDescription
                    }
                }
                .disabled(failure != nil)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(minWidth: 520, idealWidth: 600, minHeight: 340, idealHeight: 440)
    }
}
