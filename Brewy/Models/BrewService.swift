import Foundation
import OSLog
import SwiftUI

// MARK: - Logging

private let logger = Logger(subsystem: "io.linnane.brewy", category: "BrewService")

@Observable
@MainActor
final class BrewService {
    @ObservationIgnored let commandRunner: CommandRunning
    @ObservationIgnored private let masExecutablePathOverride: String?
    @ObservationIgnored private let masExecutablePathResolver: @Sendable () -> String
    @ObservationIgnored private let packageCacheURL: URL?
    @ObservationIgnored private let packageCacheWritesEnabled: Bool

    @AppStorage("brewPath")
    @ObservationIgnored var customBrewPath = "/opt/homebrew/bin/brew"

    @AppStorage("brewfilePath")
    @ObservationIgnored var customBrewfilePath = ""

    @AppStorage("trustedBrewfilePath")
    @ObservationIgnored var trustedBrewfilePath = ""

    @AppStorage("trustedBrewfileDigest")
    @ObservationIgnored var trustedBrewfileDigest = ""

    init(
        commandRunner: CommandRunning = DefaultCommandRunner(),
        masExecutablePath: String? = nil,
        masExecutablePathResolver: @escaping @Sendable () -> String = CommandRunner.resolvedMasPath,
        packageCacheURL: URL? = BrewService.runtimeDefaultPackageCacheURL,
        packageCacheWritesEnabled: Bool = !BrewyRuntime.isRunningTests
    ) {
        self.commandRunner = commandRunner
        masExecutablePathOverride = masExecutablePath
        self.masExecutablePathResolver = masExecutablePathResolver
        self.packageCacheURL = packageCacheURL
        self.packageCacheWritesEnabled = packageCacheWritesEnabled
    }

    deinit {
        initialRefreshTask?.cancel()
        autoRefreshTask?.cancel()
    }

    var masExecutablePath: String {
        masExecutablePathOverride ?? masExecutablePathResolver()
    }

    var installedFormulae: [BrewPackage] = [] {
        didSet {
            guard !isBatchingUpdates else { return }
            invalidateDerivedState()
        }
    }
    var installedCasks: [BrewPackage] = [] {
        didSet {
            guard !isBatchingUpdates else { return }
            invalidateDerivedState()
        }
    }
    var installedMasApps: [BrewPackage] = [] {
        didSet {
            guard !isBatchingUpdates else { return }
            invalidateDerivedState()
        }
    }
    private(set) var installedApplicationURLs: [String: URL] = [:]
    var isMasAvailable = false
    var outdatedPackages: [BrewPackage] = []
    var installedTaps: [BrewTap] = []
    var searchResults: [BrewPackage] = []
    private var loadingCount = 0
    var isLoading: Bool { loadingCount > 0 }
    var isPerformingAction = false
    var actionOutput: String = ""
    var canCancelCurrentAction = false
    var lastError: BrewError?
    /// Failure from a background auto-refresh, surfaced non-modally (sidebar footer)
    /// instead of the error alert so a broken brew doesn't raise a modal every interval.
    var backgroundRefreshError: BrewError?
    var lastUpdated: Date?
    var tapHealthStatuses: [String: TapHealthStatus] = [:]
    var packageGroups: [PackageGroup] = []
    var actionHistory: [ActionHistoryEntry] = []
    var lastUpdateResult: BrewUpdateResult?
    var brewfileURL: URL?
    var bundleEntries: [BrewBundleEntry] = []
    var bundleCheckStatus: BrewBundleCheckStatus = .unknown
    var isBundleLoading = false
    var vulnerabilityScan: FormulaVulnerabilityScan?
    var vulnerabilityScanError: BrewError?
    var isScanningVulnerabilities = false
    var homebrewAnalyticsStatus: HomebrewAnalyticsStatus = .unknown
    var homebrewAnalyticsError: String?
    var isUpdatingHomebrewAnalytics = false
    var tapsLoaded = false
    private var isRefreshing = false
    private var needsRefresh = false
    private var needsRefreshUserInitiated = false
    @ObservationIgnored private var isBackgroundRefresh = false
    @ObservationIgnored private var refreshReportedError = false
    @ObservationIgnored private var isBatchingUpdates = false
    @ObservationIgnored private(set) var installedFormulaFingerprint: [String: String] = [:]
    @ObservationIgnored var infoCache: [String: String] = [:]
    @ObservationIgnored private var tapHealthTask: Task<Void, Never>?
    @ObservationIgnored var actionCommandTask: Task<CommandResult, Never>?
    @ObservationIgnored var packageUpdatesStarted = false
    @ObservationIgnored var scheduledAutoRefreshInterval: Int?
    @ObservationIgnored var initialRefreshTask: Task<Void, Never>?
    @ObservationIgnored var autoRefreshTask: Task<Void, Never>?

    // MARK: - Cached Derived State

    private(set) var allInstalled: [BrewPackage] = []
    private(set) var installedNames: Set<String> = []
    private(set) var installedIDs: Set<String> = []
    private(set) var reverseDependencies: [String: [BrewPackage]] = [:]
    private(set) var leavesPackages: [BrewPackage] = []
    private(set) var pinnedPackages: [BrewPackage] = []

    private func updateInstalledPackages(formulae: [BrewPackage], casks: [BrewPackage], masApps: [BrewPackage] = []) {
        isBatchingUpdates = true
        installedFormulae = formulae
        installedCasks = casks
        installedMasApps = masApps
        isBatchingUpdates = false
        invalidateDerivedState()
    }

    private func applyRefreshResults(
        formulae: [BrewPackage],
        casks: [BrewPackage],
        masApps: [BrewPackage],
        outdated: [BrewPackage],
        applicationURLs: [String: URL]
    ) {
        isBatchingUpdates = true
        installedFormulae = formulae
        installedCasks = casks
        installedMasApps = masApps
        outdatedPackages = outdated
        installedApplicationURLs = applicationURLs
        isBatchingUpdates = false
        invalidateDerivedState()
    }

    private func invalidateDerivedState() {
        let formulaFingerprint = Dictionary(
            installedFormulae.map { ($0.id, $0.version) },
            uniquingKeysWith: { _, latest in latest }
        )
        if formulaFingerprint != installedFormulaFingerprint {
            installedFormulaFingerprint = formulaFingerprint
            vulnerabilityScan = nil
            vulnerabilityScanError = nil
        }

        let all = installedFormulae + installedCasks + installedMasApps
        allInstalled = all
        installedNames = Set(all.map(\.name))
        installedIDs = Set(all.map(\.id))

        var reverse: [String: [BrewPackage]] = [:]
        reverse.reserveCapacity(all.count)
        for pkg in all {
            for dep in pkg.dependencies {
                reverse[dep, default: []].append(pkg)
            }
        }
        reverseDependencies = reverse
        leavesPackages = installedFormulae.filter { reverse[$0.name] == nil || reverse[$0.name]!.isEmpty }
        pinnedPackages = all.filter(\.pinned)
    }

    func dependents(of name: String) -> [BrewPackage] {
        reverseDependencies[name] ?? []
    }

}

// MARK: - Cache

extension BrewService {

    nonisolated static let cacheDirectory: URL? = {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = appSupport.appendingPathComponent("Brewy", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    nonisolated private static let defaultPackageCacheURL: URL? =
        cacheDirectory?.appendingPathComponent("packageCache.json")

    nonisolated private static var runtimeDefaultPackageCacheURL: URL? {
        guard !BrewyRuntime.isRunningTests else { return nil }
        return defaultPackageCacheURL
    }

    /// Current schema version for the package cache. Bump when `CachedData` gains a non-optional
    /// field or changes semantics so old caches are deleted rather than silently discarded each launch.
    static let cacheSchemaVersion = 1

    private struct CachedData: Codable {
        let schemaVersion: Int
        let formulae: [BrewPackage]
        let casks: [BrewPackage]
        let masApps: [BrewPackage]?
        let outdated: [BrewPackage]
        let taps: [BrewTap]
        let lastUpdated: Date
    }

    func loadFromCache() {
        guard let packageCacheURL else { return }
        do {
            let data = try Data(contentsOf: packageCacheURL)
            let cached = try JSONDecoder().decode(CachedData.self, from: data)
            guard cached.schemaVersion == Self.cacheSchemaVersion else {
                logger.warning("Cache schema version \(cached.schemaVersion) != \(Self.cacheSchemaVersion), discarding")
                if packageCacheWritesEnabled {
                    try? FileManager.default.removeItem(at: packageCacheURL)
                }
                return
            }
            let masApps = cached.masApps ?? []
            updateInstalledPackages(formulae: cached.formulae, casks: cached.casks, masApps: masApps)
            outdatedPackages = cached.outdated
            installedTaps = cached.taps
            tapsLoaded = !cached.taps.isEmpty
            isMasAvailable = !masApps.isEmpty || FileManager.default.isExecutableFile(atPath: masExecutablePath)
            lastUpdated = cached.lastUpdated
            logger.info("Loaded \(cached.formulae.count) formulae and \(cached.casks.count) casks from cache")
        } catch {
            logger.warning("Failed to load cache: \(error.localizedDescription)")
            if packageCacheWritesEnabled {
                try? FileManager.default.removeItem(at: packageCacheURL)
            }
        }
    }

    func saveToCache() async {
        guard let packageCacheURL, packageCacheWritesEnabled else { return }
        let cached = CachedData(
            schemaVersion: Self.cacheSchemaVersion,
            formulae: installedFormulae,
            casks: installedCasks,
            masApps: installedMasApps,
            outdated: outdatedPackages,
            taps: installedTaps,
            lastUpdated: lastUpdated ?? Date()
        )
        do {
            try await Task.detached(priority: .utility) {
                let data = try JSONEncoder().encode(cached)
                try data.write(to: packageCacheURL, options: .atomic)
            }.value
            logger.debug("Cache saved successfully")
        } catch {
            logger.error("Failed to save cache: \(error.localizedDescription)")
        }
    }

    // MARK: - Tap Health

    func loadTapHealthCache() {
        tapHealthStatuses = TapHealthChecker.loadCache()
    }

    func checkTapHealth() async {
        guard !BrewyRuntime.isRunningTests else { return }
        let updated = await TapHealthChecker.checkHealth(taps: installedTaps, existing: tapHealthStatuses)
        guard !Task.isCancelled else { return }
        tapHealthStatuses = updated
    }
}

// MARK: - Homebrew CLI Interactions

extension BrewService {

    func refresh(isUserInitiated: Bool = true) async {
        guard !isRefreshing else {
            needsRefresh = true
            // A queued follow-up runs as user-initiated if any queued request was.
            needsRefreshUserInitiated = needsRefreshUserInitiated || isUserInitiated
            logger.info("Refresh already in progress, queuing follow-up")
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        var userInitiated = isUserInitiated
        repeat {
            needsRefresh = false
            needsRefreshUserInitiated = false
            await performRefresh(isUserInitiated: userInitiated)
            userInitiated = needsRefreshUserInitiated
        } while needsRefresh
    }

    /// Routes fetch failures to the modal alert for user-initiated refreshes, or to the
    /// non-modal `backgroundRefreshError` when a background auto-refresh fails.
    func reportFetchError(command: String, output: String) {
        refreshReportedError = true
        let error = BrewError.commandFailed(command: command, output: output)
        if isBackgroundRefresh {
            backgroundRefreshError = error
        } else {
            lastError = error
        }
    }

    private func performRefresh(isUserInitiated: Bool) async {
        logger.info("Starting full refresh")
        isBackgroundRefresh = !isUserInitiated
        refreshReportedError = false
        defer { isBackgroundRefresh = false }
        let previousVersions = Dictionary(allInstalled.map { ($0.id, $0.version) }, uniquingKeysWith: { _, last in last })
        let hadCachedData = !installedFormulae.isEmpty || !installedCasks.isEmpty
        // Only show the spinner when there's no cached data yet; the counter keeps a concurrent
        // search() from clearing it early (and vice versa).
        let showsSpinner = !hadCachedData
        if showsSpinner { loadingCount += 1 }
        defer {
            if showsSpinner { loadingCount -= 1 }
        }

        async let installed = fetchInstalledPackages()
        async let outdated = fetchOutdatedPackages()
        async let masApps = fetchInstalledMasApps()
        async let masOutdated = fetchOutdatedMasApps()
        async let taps = fetchTaps()

        // Preserve the previously loaded list when a fetch fails (nil) rather than clobbering it
        // to empty — a transient `brew` failure shouldn't blank out (and then cache) good data.
        let fetchedInstalled = await installed
        let fetchedFormulae = fetchedInstalled?.formulae ?? installedFormulae
        let fetchedCasks = fetchedInstalled?.casks ?? installedCasks
        let fetchedOutdated = await outdated ?? outdatedPackages.filter { $0.source != .mas }
        let fetchedMas = await masApps
        let fetchedMasApps = fetchedMas?.packages ?? installedMasApps
        let fetchedMasOutdated = await masOutdated ?? outdatedPackages.filter(\.isMas)
        let fetchedTaps = await taps ?? installedTaps
        let merged = Self.mergeRefreshPackages(
            formulae: fetchedFormulae,
            casks: fetchedCasks,
            masApps: fetchedMasApps,
            outdated: fetchedOutdated + fetchedMasOutdated
        )
        let applicationURLs = Self.refreshedApplicationURLs(
            existingURLs: installedApplicationURLs,
            brewURLs: fetchedInstalled?.applicationURLs,
            masURLs: fetchedMas?.applicationURLs,
            installedIDs: merged.installedIDs
        )

        applyRefreshResults(
            formulae: merged.formulae,
            casks: merged.casks,
            masApps: merged.masApps,
            outdated: merged.outdated,
            applicationURLs: applicationURLs
        )
        lastUpdated = Date()

        let masCount = fetchedMasApps.count
        let outdatedCount = merged.outdated.count
        logger.info("Refresh complete: \(fetchedFormulae.count) formulae, \(fetchedCasks.count) casks, \(masCount) mas, \(outdatedCount) outdated")
        await finishRefresh(previousVersions: previousVersions, taps: fetchedTaps)
    }

    private func finishRefresh(previousVersions: [String: String], taps: [BrewTap]) async {
        let currentVersions = Dictionary(allInstalled.map { ($0.id, $0.version) }, uniquingKeysWith: { _, last in last })
        for id in infoCache.keys where currentVersions[id] != previousVersions[id] {
            infoCache.removeValue(forKey: id)
        }

        installedTaps = taps
        tapsLoaded = true
        updateBundleEntryStatuses()

        if !refreshReportedError {
            backgroundRefreshError = nil
        }

        await saveToCache()
        // Cancel any in-flight check unconditionally so a prior refresh's task can't overwrite
        // tapHealthStatuses after the tap list has changed.
        tapHealthTask?.cancel()
        if installedTaps.contains(where: { tapHealthStatuses[$0.name]?.isStale ?? true }) {
            tapHealthTask = Task { [weak self] in
                await self?.checkTapHealth()
            }
        }
    }

    func search(query: String) async {
        guard !query.isEmpty else {
            searchResults = []
            return
        }

        loadingCount += 1
        defer { loadingCount -= 1 }
        lastError = nil

        let results = await performSearch(query: query)
        guard !Task.isCancelled else { return }
        searchResults = results
    }

    func upgradeSelected(packages: [BrewPackage]) async {
        guard !isPerformingAction else {
            logger.info("upgradeSelected skipped, action already in progress")
            return
        }
        isPerformingAction = true
        actionOutput = ""
        lastError = nil
        defer { isPerformingAction = false }

        let formulae = packages.filter { $0.source == .formula }.map(\.name)
        let casks = packages.filter { $0.source == .cask }.map(\.name)
        let masCount = packages.filter(\.isMas).count
        var errorOutputs: [String] = []
        var wasCancelled = false

        if !formulae.isEmpty {
            let args = ["upgrade", "--"] + formulae
            let result = await runBrewCommandStreaming(args)
            wasCancelled = result.cancelled
            if !result.success, !result.cancelled { errorOutputs.append(result.output) }
            recordAction(arguments: args, packageName: nil, packageSource: .formula, success: result.success, output: result.output)
        }
        if !casks.isEmpty, !wasCancelled {
            let args = ["upgrade", "--cask", "--"] + casks
            let result = await runBrewCommandStreaming(args)
            wasCancelled = result.cancelled
            if !result.success, !result.cancelled { errorOutputs.append(result.output) }
            recordAction(arguments: args, packageName: nil, packageSource: .cask, success: result.success, output: result.output)
        }
        if !errorOutputs.isEmpty {
            lastError = .commandFailed(command: "upgrade", output: errorOutputs.joined(separator: "\n\n"))
        } else if masCount > 0, !wasCancelled {
            lastError = .commandFailed(command: "upgrade", output: Self.masUpgradeMessage(count: masCount))
        }
        await refresh()
    }

    func runBrewCommand(_ arguments: [String]) async -> CommandResult {
        let brewPath = CommandRunner.resolvedBrewPath(preferred: customBrewPath)
        return await commandRunner.run(
            arguments,
            brewPath: brewPath,
            timeout: CommandRunner.timeout(forBrewArguments: arguments)
        )
    }

}

// MARK: - Package Category Queries

extension BrewService {

    func packages(for category: SidebarCategory) -> [BrewPackage] {
        switch category {
        case .installed: allInstalled
        case .formulae: installedFormulae
        case .casks: installedCasks
        case .masApps: installedMasApps
        case .outdated: outdatedPackages
        case .pinned: pinnedPackages
        case .leaves: leavesPackages
        case .taps: []
        case .services: []
        case .groups: []
        case .bundle: []
        case .history: []
        case .discover: searchResults
        case .security: []
        case .maintenance: []
        }
    }

    var homebrewOutdatedPackages: [BrewPackage] {
        outdatedPackages.filter { !$0.isMas }
    }
}
