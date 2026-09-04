import SwiftUI

enum ReleaseNotesFeed {
    enum FeedError: LocalizedError {
        case responseTooLarge

        var errorDescription: String? {
            "The release-notes feed is larger than Brewy accepts."
        }
    }

    static func load(from url: URL, session: URLSession = .shared) async throws -> (Data, HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(from: url)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        if httpResponse.expectedContentLength > AppcastParser.maximumFeedByteCount {
            throw FeedError.responseTooLarge
        }

        var data = Data()
        data.reserveCapacity(min(Int(max(0, httpResponse.expectedContentLength)), AppcastParser.maximumFeedByteCount))
        for try await byte in bytes {
            guard data.count < AppcastParser.maximumFeedByteCount else {
                throw FeedError.responseTooLarge
            }
            data.append(byte)
        }
        return (data, httpResponse)
    }

    @MainActor
    static func parseAndRender(_ data: Data) async -> (AppcastRelease?, AttributedString?) {
        let release = await Task.detached(priority: .userInitiated) {
            AppcastParser().parse(data: data)
        }.value
        guard !Task.isCancelled else { return (nil, nil) }
        let notes = release?.descriptionHTML.flatMap {
            ReleaseNotesHTML.attributedString(from: $0)
        }
        return (release, notes)
    }
}

struct WhatsNewView: View {
    @Environment(\.dismiss)
    private var dismiss
    @State private var release: AppcastRelease?
    @State private var parsedNotes: AttributedString?
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(width: 520, height: 400)
        .task { await fetchLatestRelease() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("What's New")
                    .font(.title2)
                    .fontWeight(.semibold)
                if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
                    Text("Brewy \(version)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding()
    }

    // MARK: - Content

    @ViewBuilder private var content: some View {
        if isLoading {
            VStack {
                Spacer()
                ProgressView("Loading release notes…")
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else if let errorMessage {
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Retry") {
                    Task { await fetchLatestRelease() }
                }
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .padding()
        } else if let release {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(release.version ?? release.title)
                            .font(.headline)
                        if let date = release.publishedDate {
                            Spacer()
                            Text(date, format: .dateTime.month(.abbreviated).day().year())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let attributed = parsedNotes {
                        Text(attributed)
                            .font(.callout)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding()
            }
        }
    }

    // MARK: - Networking

    private func fetchLatestRelease() async {
        isLoading = true
        errorMessage = nil

        guard let feedURL = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let url = ExternalURLPolicy.url(from: feedURL) else {
            errorMessage = "No update feed configured."
            isLoading = false
            return
        }

        do {
            let (data, response) = try await ReleaseNotesFeed.load(from: url)

            guard (200...299).contains(response.statusCode) else {
                errorMessage = "Failed to load release notes.\nPlease check your internet connection."
                isLoading = false
                return
            }

            let parsed = await ReleaseNotesFeed.parseAndRender(data)
            guard !Task.isCancelled else { return }
            release = parsed.0
            parsedNotes = parsed.1
            if parsed.0 == nil {
                errorMessage = "No release notes found."
            }
            isLoading = false
        } catch {
            errorMessage = "Failed to load release notes.\n\(error.localizedDescription)"
            isLoading = false
        }
    }
}
