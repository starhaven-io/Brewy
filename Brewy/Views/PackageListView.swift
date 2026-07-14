import SwiftUI

enum SearchScope: String, CaseIterable {
    case all = "All Packages"
    case installed = "Installed Only"
}

struct PackageListView: View {
    @Environment(BrewService.self)
    private var brewService
    let selectedCategory: SidebarCategory?
    @Binding var selectedPackage: BrewPackage?
    @Binding var searchText: String
    @State private var searchScope: SearchScope = .installed
    @State private var searchTask: Task<Void, Never>?
    @State private var isSearchPresented = false
    // periphery:ignore - Read and written through toolbar and row-selection bindings.
    @State private var selectedForUpgrade: Set<String> = []
    @State private var isSelectingForUpgrade = false

    private var isOutdatedCategory: Bool {
        selectedCategory == .outdated
    }

    private var isSearchingAll: Bool {
        isSearchPresented && searchScope == .all
    }

    private var displayedPackages: [BrewPackage] {
        if isSearchingAll {
            if !brewService.searchResults.isEmpty {
                return brewService.searchResults
            }
            return []
        }

        guard let category = selectedCategory else { return [] }
        let base = brewService.packages(for: category)

        if searchText.isEmpty {
            return base
        }

        return base.filter { $0.name.localizedStandardContains(searchText) }
    }

    var body: some View {
        let packages = displayedPackages
        return packageList(packages: packages)
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .searchable(text: $searchText, isPresented: $isSearchPresented, prompt: searchPrompt)
            .searchScopes($searchScope, activation: .onSearchPresentation) {
                ForEach(SearchScope.allCases, id: \.self) { scope in
                    Text(scope.rawValue).tag(scope)
                }
            }
            .onChange(of: searchText) {
                searchTask?.cancel()
                guard isSearchingAll else { return }
                guard !searchText.isEmpty else {
                    brewService.searchResults = []
                    return
                }
                searchTask = Task {
                    try? await Task.sleep(for: .milliseconds(300))
                    guard !Task.isCancelled else { return }
                    await brewService.search(query: searchText)
                }
            }
            .onChange(of: searchScope) {
                guard isSearchingAll else {
                    brewService.searchResults = []
                    return
                }
                if !searchText.isEmpty {
                    searchTask?.cancel()
                    searchTask = Task {
                        await brewService.search(query: searchText)
                    }
                }
            }
            .onChange(of: isSearchPresented) {
                guard !isSearchPresented else { return }
                searchTask?.cancel()
                brewService.searchResults = []
            }
            .onChange(of: selectedCategory) {
                searchScope = .installed
                searchText = ""
                searchTask?.cancel()
                brewService.searchResults = []
                // selectedPackage is cleared centrally in ContentView.onChange(of: selectedCategory).
            }
            .overlay {
                if brewService.isLoading, packages.isEmpty {
                    ProgressView("Loading packages...")
                }
            }
            .navigationTitle(navigationTitle)
            .navigationSubtitle("\(packages.count) packages")
            .toolbar {
                PackageListToolbar(
                    isOutdated: isOutdatedCategory,
                    isSelecting: $isSelectingForUpgrade,
                    selectedForUpgrade: $selectedForUpgrade,
                    outdatedPackages: isOutdatedCategory ? packages.filter { !$0.isMas } : []
                )
            }
    }

    private func packageList(packages: [BrewPackage]) -> some View {
        List(selection: $selectedPackage) {
            if packages.isEmpty {
                emptyContent
            } else {
                ForEach(packages) { package in
                    HStack(spacing: 10) {
                        if isOutdatedCategory, isSelectingForUpgrade {
                            if !package.isMas {
                                UpgradeSelectionToggle(
                                    packageID: package.id,
                                    selectedForUpgrade: $selectedForUpgrade
                                )
                            }
                        }
                        PackageRow(
                            package: package,
                            showInstalledBadge: isSearchingAll,
                            showUpgradeButton: isOutdatedCategory && !isSelectingForUpgrade,
                            onUpgrade: { pkg in await brewService.upgrade(package: pkg) }
                        )
                    }
                    .tag(package)
                }
            }
        }
    }

    private var searchPrompt: String {
        "Search packages..."
    }

    private var navigationTitle: String {
        selectedCategory?.rawValue ?? "Packages"
    }

    @ViewBuilder private var emptyContent: some View {
        if brewService.isLoading {
            EmptyView()
        } else if isSearchingAll, searchText.isEmpty {
            ContentUnavailableView(
                "Search Homebrew",
                systemImage: "magnifyingglass",
                description: Text("Type a package name to search all of Homebrew.")
            )
        } else if isSearchingAll {
            ContentUnavailableView.search(text: searchText)
        } else {
            ContentUnavailableView(
                "No Packages",
                systemImage: "shippingbox",
                description: Text("No packages found in this category.")
            )
        }
    }
}

// MARK: - Toolbar

private struct PackageListToolbar: ToolbarContent {
    @Environment(BrewService.self)
    private var brewService
    let isOutdated: Bool
    @Binding var isSelecting: Bool
    @Binding var selectedForUpgrade: Set<String>
    let outdatedPackages: [BrewPackage]

    var body: some ToolbarContent {
        if isOutdated, !outdatedPackages.isEmpty {
            if isSelecting {
                ToolbarItem(placement: .primaryAction) {
                    Button("Upgrade (\(selectedForUpgrade.count))") {
                        let toUpgrade = outdatedPackages.filter { selectedForUpgrade.contains($0.id) }
                        Task {
                            await brewService.upgradeSelected(packages: toUpgrade)
                            selectedForUpgrade.removeAll()
                            isSelecting = false
                        }
                    }
                    .disabled(selectedForUpgrade.isEmpty)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        selectedForUpgrade.removeAll()
                        isSelecting = false
                    }
                }
            } else {
                ToolbarItem(placement: .primaryAction) {
                    Button("Upgrade All") {
                        Task { await brewService.upgradeAll() }
                    }
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button("Select") {
                        isSelecting = true
                    }
                }
            }
        } else if !brewService.homebrewOutdatedPackages.isEmpty {
            ToolbarItem(placement: .primaryAction) {
                Button("Upgrade All") {
                    Task { await brewService.upgradeAll() }
                }
            }
        }
    }
}

// MARK: - Upgrade Selection Toggle

private struct UpgradeSelectionToggle: View {
    let packageID: String
    @Binding var selectedForUpgrade: Set<String>

    var body: some View {
        Toggle(isOn: Binding(
            get: { selectedForUpgrade.contains(packageID) },
            set: { isSelected in
                if isSelected {
                    selectedForUpgrade.insert(packageID)
                } else {
                    selectedForUpgrade.remove(packageID)
                }
            }
        )) { EmptyView() }
        .toggleStyle(.checkbox)
        .labelsHidden()
    }
}

// MARK: - Package Row

private struct PackageRow: View {
    let package: BrewPackage
    var showInstalledBadge = false
    var showUpgradeButton = false
    var onUpgrade: ((BrewPackage) async -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            PackageSourceIcon(source: package.source, size: 28)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(package.name)
                        .font(.body)
                        .fontWeight(.semibold)
                        .accessibilityIdentifier("package-row-\(package.name)")
                    if showInstalledBadge, package.isInstalled {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                            .accessibilityLabel("Installed")
                    }
                    PackageSourceBadge(source: package.source)
                    if package.pinned {
                        BrewyStatusBadge("pinned", systemImage: "pin.fill", color: .brewyAccent)
                    }
                }
                if !package.description.isEmpty {
                    Text(package.description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            versionLabel
            if showUpgradeButton, package.isOutdated, !package.isMas {
                Button {
                    Task { await onUpgrade?(package) }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Color.brewyAccent)
                }
                .buttonStyle(.plain)
                .help("Upgrade \(package.name)")
                .accessibilityLabel("Upgrade \(package.name)")
            }
        }
        .padding(.vertical, 4)
    }

    private var versionLabel: some View {
        Group {
            if package.isOutdated {
                Label(package.displayVersion, systemImage: "arrow.up.circle.fill")
                    .font(.caption)
                    .foregroundStyle(Color.brewyAccent)
            } else if !package.version.isEmpty {
                Text(package.version)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }
}
