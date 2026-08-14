import SwiftUI

extension Notification.Name {
    static let showWhatsNew = Notification.Name("showWhatsNew")
    static let showCleanupPreview = Notification.Name("showCleanupPreview")
}

// MARK: - Package Navigation Environment

// A manual EnvironmentKey instead of @Entry: the macro rejects closure-typed
// defaults as non-comparable, which SWIFT_TREAT_WARNINGS_AS_ERRORS turns into a build error.
private struct SelectPackageKey: EnvironmentKey {
    static let defaultValue: @MainActor @Sendable (String) -> Void = { _ in }
}

extension EnvironmentValues {
    var selectPackage: @MainActor @Sendable (String) -> Void {
        get { self[SelectPackageKey.self] }
        set { self[SelectPackageKey.self] = newValue }
    }
}

struct ContentView: View {
    @Environment(BrewService.self)
    private var brewService
    @AppStorage("autoRefreshInterval")
    private var autoRefreshInterval = 0
    @AppStorage("showCasksByDefault")
    private var showCasksByDefault = false
    @AppStorage("lastSeenVersion")
    private var lastSeenVersion = ""
    @State private var selectedCategory: SidebarCategory? = .installed
    @State private var selectedPackage: BrewPackage?
    @State private var pendingPackageSelection: BrewPackage?
    @State private var selectedTap: BrewTap?
    @State private var selectedServiceItem: BrewServiceItem?
    @State private var selectedGroupItem: PackageGroup?
    @State private var selectedHistoryEntry: ActionHistoryEntry?
    @State private var servicesRefreshTrigger = 0
    // periphery:ignore - Mutated through PackageListView's search binding.
    @State private var searchText = ""
    @State private var showWhatsNew = false
    @State private var showCleanupConfirm = false

    var body: some View {
        NavigationSplitView {
            SidebarView(
                selectedCategory: $selectedCategory
            )
            .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 300)
        } content: {
            if selectedCategory == .masApps, !brewService.isMasAvailable {
                MasSetupView()
                    .navigationSplitViewColumnWidth(min: 400, ideal: 600, max: .infinity)
            } else if selectedCategory == .taps {
                TapListView(selectedTap: $selectedTap)
                    .navigationSplitViewColumnWidth(min: 300, ideal: 350, max: 500)
            } else if selectedCategory == .services {
                ServicesView(selectedService: $selectedServiceItem, refreshTrigger: servicesRefreshTrigger)
                    .navigationSplitViewColumnWidth(min: 300, ideal: 350, max: 500)
            } else if selectedCategory == .groups {
                GroupsView(selectedGroup: $selectedGroupItem)
                    .navigationSplitViewColumnWidth(min: 300, ideal: 350, max: 500)
            } else if selectedCategory == .bundle {
                BundleView()
                    .navigationSplitViewColumnWidth(min: 400, ideal: 600, max: .infinity)
            } else if selectedCategory == .history {
                HistoryView(selectedEntry: $selectedHistoryEntry)
                    .navigationSplitViewColumnWidth(min: 300, ideal: 350, max: 500)
            } else if selectedCategory == .discover {
                DiscoverView(selectedPackage: $selectedPackage)
                    .navigationSplitViewColumnWidth(min: 300, ideal: 350, max: 500)
            } else if selectedCategory == .maintenance {
                MaintenanceView()
                    .navigationSplitViewColumnWidth(min: 400, ideal: 600, max: .infinity)
            } else {
                PackageListView(
                    selectedCategory: selectedCategory,
                    selectedPackage: $selectedPackage,
                    searchText: $searchText
                )
                .navigationSplitViewColumnWidth(min: 300, ideal: 350, max: 500)
            }
        } detail: {
            detailView
        }
        .environment(\.selectPackage) { name in navigateToPackage(name) }
        .overlay {
            if brewService.isPerformingAction {
                ZStack {
                    Color.black.opacity(0.12)
                    ActionOverlay(
                        output: brewService.actionOutput,
                        canCancel: brewService.canCancelCurrentAction,
                        onCancel: brewService.cancelCurrentAction
                    )
                }
                .accessibilityAddTraits(.isModal)
            }
        }
        .task {
#if DEBUG
            if BrewyRuntime.isUITesting { return }
#endif
            if showCasksByDefault {
                selectedCategory = .casks
            }
            brewService.loadTapHealthCache()
            brewService.loadGroups()
            brewService.loadHistory()
            brewService.loadLastUpdateResult()
            // Skip non-deterministic startup work under unit tests.
            guard !BrewyRuntime.isRunningTests else { return }
            let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
            if !currentVersion.isEmpty, currentVersion != lastSeenVersion {
                lastSeenVersion = currentVersion
                showWhatsNew = true
            }
            await brewService.refreshBundle()
        }
        .task(id: autoRefreshInterval) {
            brewService.startPackageUpdates(autoRefreshInterval: autoRefreshInterval)
        }
        .onChange(of: selectedCategory) {
            // Cleared here (not in PackageListView, which is torn down when switching to a
            // non-package category like Discover and would leave a stale detail showing).
            selectedPackage = nil
            selectedTap = nil
            selectedServiceItem = nil
            selectedGroupItem = nil
            selectedHistoryEntry = nil
            if let pendingPackageSelection {
                selectedPackage = pendingPackageSelection
                self.pendingPackageSelection = nil
            }
        }
        .alert(
            "Error",
            isPresented: Binding(
                get: { brewService.lastError != nil },
                set: { if !$0 { brewService.lastError = nil } }
            ),
            presenting: brewService.lastError
        ) { _ in
            Button("OK") { brewService.lastError = nil }
        } message: { error in
            Text(error.localizedDescription)
        }
        .sheet(isPresented: $showWhatsNew) {
            WhatsNewView()
        }
        .sheet(isPresented: $showCleanupConfirm) {
            DryRunConfirmationSheet.clearCache(brewService: brewService)
        }
        .onReceive(NotificationCenter.default.publisher(for: .showWhatsNew)) { _ in
            showWhatsNew = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .showCleanupPreview)) { _ in
            showCleanupConfirm = true
        }
    }

    @ViewBuilder private var detailView: some View {
        if selectedCategory == .maintenance || selectedCategory == .bundle
            || (selectedCategory == .masApps && !brewService.isMasAvailable) {
            Color.clear
                .navigationSplitViewColumnWidth(0)
        } else if selectedCategory == .services, let service = selectedServiceItem {
            ServiceDetailView(service: service) {
                servicesRefreshTrigger &+= 1
            }
            .id(service.id)
            .navigationSplitViewColumnWidth(ideal: 450)
        } else if selectedCategory == .services {
            EmptyStateView(
                icon: "gearshape.2",
                title: "Select a Service",
                subtitle: "Choose a service from the list to view its details and controls."
            )
        } else if selectedCategory == .groups, let group = selectedGroupItem,
                  let currentGroup = brewService.packageGroups.first(where: { $0.id == group.id }) {
            GroupDetailView(group: currentGroup)
                .id(group.id)
                .navigationSplitViewColumnWidth(ideal: 450)
        } else if selectedCategory == .groups {
            EmptyStateView(
                icon: "folder",
                title: "Select a Group",
                subtitle: "Choose a group from the list to view its packages."
            )
        } else if selectedCategory == .history, let entry = selectedHistoryEntry {
            HistoryDetailView(entry: entry)
                .id(entry.id)
                .navigationSplitViewColumnWidth(ideal: 450)
        } else if selectedCategory == .history {
            EmptyStateView(
                icon: "clock.arrow.circlepath",
                title: "Select an Action",
                subtitle: "Choose an action from the history to view its details."
            )
        } else if selectedCategory == .taps, let tap = selectedTap {
            TapDetailView(tap: tap)
        } else if selectedCategory == .taps {
            EmptyStateView(
                icon: "spigot",
                title: "Select a Tap",
                subtitle: "Choose a tap from the list to view its details."
            )
        } else if let selectedPackage {
            let package = brewService.allInstalled.first(where: { $0.id == selectedPackage.id }) ?? selectedPackage
            PackageDetailView(package: package)
                .id(package.id)
                .navigationSplitViewColumnWidth(ideal: 450)
        } else {
            EmptyStateView(lastUpdated: brewService.lastUpdated)
                .navigationSplitViewColumnWidth(ideal: 450)
        }
    }

    private func navigateToPackage(_ name: String) {
        if let match = brewService.allInstalled.first(where: { $0.name == name }) {
            let destination: SidebarCategory = switch match.source {
            case .formula: .formulae
            case .cask: .casks
            case .mas: .masApps
            }
            if selectedCategory == destination {
                pendingPackageSelection = nil
                selectedPackage = match
            } else {
                pendingPackageSelection = match
                selectedCategory = destination
            }
        }
    }
}

// MARK: - Empty State

private struct EmptyStateView: View {
    var icon: String = "shippingbox"
    var title: String = "Select a Package"
    var subtitle: String = "Choose a package from the list to view its details."
    var lastUpdated: Date?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.tertiary)
            if icon == "shippingbox" {
                Text("\u{2318}R to refresh  \u{00B7}  \u{2318}U to upgrade all")
                    .font(.caption)
                    .foregroundStyle(.quaternary)
                    .padding(.top, 4)
            }
            if let lastUpdated {
                Text("Last refreshed \(Self.relativeTime(since: lastUpdated))")
                    .font(.caption2)
                    .foregroundStyle(.quaternary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private static func relativeTime(since date: Date) -> String {
        let minutes = Int(Date().timeIntervalSince(date) / 60)
        if minutes < 1 { return "just now" }
        if minutes == 1 { return "1 min ago" }
        if minutes < 60 { return "\(minutes) min ago" }
        let hours = minutes / 60
        if hours == 1 { return "1 hour ago" }
        return "\(hours) hours ago"
    }
}
