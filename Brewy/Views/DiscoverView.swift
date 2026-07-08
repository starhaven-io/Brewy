import SwiftUI

struct DiscoverView: View {
    @Environment(BrewService.self)
    private var brewService
    @Binding var selectedPackage: BrewPackage?
    @State private var searchText = ""
    @State private var searchResults: [BrewPackage] = []
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?

    private var recentPackages: [BrewPackage] {
        guard searchText.isEmpty,
              let result = brewService.lastUpdateResult,
              !result.isEmpty else { return [] }
        return result.discoverPackages(installedPackageIDs: brewService.installedIDs)
    }

    private var displayedPackages: [BrewPackage] {
        searchText.isEmpty ? recentPackages : searchResults
    }

    var body: some View {
        let packages = displayedPackages
        List(selection: $selectedPackage) {
            if packages.isEmpty {
                emptyContent
            } else {
                if searchText.isEmpty, let result = brewService.lastUpdateResult {
                    Section {
                        packageRows(packages)
                    } header: {
                        Text("New since \(result.timestamp.formatted(.relative(presentation: .named)))")
                    }
                } else {
                    packageRows(packages)
                }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .searchable(text: $searchText, prompt: "Search all of Homebrew...")
        .onChange(of: searchText) {
            searchTask?.cancel()
            guard !searchText.isEmpty else {
                searchResults = []
                isSearching = false
                return
            }
            searchTask = Task {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                isSearching = true
                let fetched = await brewService.performSearch(query: searchText)
                guard !Task.isCancelled else { return }
                searchResults = fetched
                isSearching = false
            }
        }
        .overlay {
            if isSearching, !searchText.isEmpty, searchResults.isEmpty {
                ProgressView("Searching...")
            }
        }
        .navigationTitle("Discover")
        .navigationSubtitle(navigationSubtitle(for: packages.count))
    }

    @ViewBuilder
    private func packageRows(_ packages: [BrewPackage]) -> some View {
        ForEach(packages) { package in
            DiscoverRow(
                package: package,
                onInstall: { pkg in await brewService.install(package: pkg) }
            )
            .tag(package)
        }
    }

    private func navigationSubtitle(for count: Int) -> String {
        if searchText.isEmpty {
            guard count > 0 else { return "Search to find new packages" }
            return count == 1 ? "1 new package" : "\(count) new packages"
        }
        return "\(count) results"
    }

    @ViewBuilder private var emptyContent: some View {
        if searchText.isEmpty {
            ContentUnavailableView(
                "Find New Packages",
                systemImage: "magnifyingglass",
                description: Text("Search all of Homebrew to discover and install formulae and casks.")
            )
        } else if !isSearching {
            ContentUnavailableView.search(text: searchText)
        }
    }
}

// MARK: - Discover Row

private struct DiscoverRow: View {
    let package: BrewPackage
    var onInstall: ((BrewPackage) async -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            PackageSourceIcon(source: package.source, size: 28)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(package.name)
                        .font(.body)
                        .fontWeight(.semibold)
                    if package.isInstalled {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                            .accessibilityLabel("Installed")
                    }
                    PackageSourceBadge(source: package.source)
                }
                if !package.description.isEmpty {
                    Text(package.description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer()

            if package.isInstalled {
                Text("Installed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button {
                    Task { await onInstall?(package) }
                } label: {
                    Label("Install", systemImage: "arrow.down.circle.fill")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .tint(.blue)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }
}
