import CryptoKit
import Foundation
import OSLog

private let logger = Logger(subsystem: "io.linnane.brewy", category: "BrewService+Bundle")

// MARK: - Brew Bundle Models

enum BrewBundleEntryType: String, CaseIterable, Identifiable, Hashable {
    case formula
    case cask
    case tap
    case mas

    var id: String { rawValue }

    var listFlag: String {
        switch self {
        case .formula: "--formula"
        case .cask: "--cask"
        case .tap: "--tap"
        case .mas: "--mas"
        }
    }

    var title: String {
        switch self {
        case .formula: "Formulae"
        case .cask: "Casks"
        case .tap: "Taps"
        case .mas: "Mac App Store"
        }
    }

    var systemImage: String {
        switch self {
        case .formula: "terminal.fill"
        case .cask: "macwindow"
        case .tap: "spigot.fill"
        case .mas: "app.badge.fill"
        }
    }
}

enum BrewBundleEntryStatus: Hashable {
    case installed
    case missing
    case unknown
}

struct BrewBundleEntry: Identifiable, Hashable {
    let type: BrewBundleEntryType
    let name: String
    let status: BrewBundleEntryStatus

    var id: String { "\(type.rawValue)-\(name)" }
}

enum BrewBundleCheckStatus: Equatable {
    case unknown
    case noBrewfile
    case untrusted
    case checking
    case satisfied
    case unsatisfied([String])
    case failed(String)
}

// MARK: - Brewfile Discovery

enum BrewfileDiscovery {

    static func resolve(
        overridePath: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> URL? {
        let trimmedOverride = overridePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedOverride.isEmpty {
            return existingURL(atPath: trimmedOverride, fileExists: fileExists)
        }

        var candidates: [String] = []
        if let xdgConfigHome = environment["XDG_CONFIG_HOME"], !xdgConfigHome.isEmpty {
            candidates.append(
                URL(fileURLWithPath: expandedPath(xdgConfigHome))
                    .appendingPathComponent("homebrew/Brewfile")
                    .path
            )
        }
        candidates.append(homeDirectory.appendingPathComponent(".homebrew/Brewfile").path)
        candidates.append(homeDirectory.appendingPathComponent(".Brewfile").path)

        for candidate in candidates {
            if let url = existingURL(atPath: candidate, fileExists: fileExists) {
                return url
            }
        }
        return nil
    }

    private static func existingURL(atPath path: String, fileExists: (String) -> Bool) -> URL? {
        let expanded = expandedPath(path)
        guard fileExists(expanded) else { return nil }
        return URL(fileURLWithPath: expanded).resolvingSymlinksInPath()
    }

    private static func expandedPath(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }
}

// MARK: - Brew Bundle Parser

enum BrewBundleParser {

    static func parseList(_ output: String) -> [String] {
        output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func parseCheckResult(success: Bool, output: String) -> BrewBundleCheckStatus {
        if success { return .satisfied }

        let missing = parseMissingDependencies(output)
        if !missing.isEmpty { return .unsatisfied(missing) }

        let message = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return .failed(message.isEmpty ? "brew bundle check failed." : message)
    }

    private static func parseMissingDependencies(_ output: String) -> [String] {
        var missing: [String] = []
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            if let dependency = dependencyNeedingInstall(from: line) {
                missing.append(dependency)
            }
        }
        return missing
    }

    private static func dependencyNeedingInstall(from line: String) -> String? {
        let normalized = stripLeadingMarker(from: line)
        let suffixes = [
            " needs to be installed or updated.",
            " needs to be installed or updated",
            " need to be installed or updated.",
            " need to be installed or updated",
            " needs to be installed.",
            " needs to be installed",
            " need to be installed.",
            " need to be installed"
        ]
        for suffix in suffixes where normalized.hasSuffix(suffix) {
            return String(normalized.dropLast(suffix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private static func stripLeadingMarker(from line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, ["→", "•", "-", "*"].contains(first) else {
            return trimmed
        }
        return String(trimmed.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - BrewService Bundle Integration

extension BrewService {

    var bundleEntryCount: Int? {
        guard brewfileURL != nil else { return nil }
        return bundleEntries.count
    }

    @discardableResult
    func resolveBrewfile() -> URL? {
        let url = BrewfileDiscovery.resolve(overridePath: customBrewfilePath)
        brewfileURL = url
        if url == nil {
            bundleEntries = []
            bundleCheckStatus = .noBrewfile
        } else if let url, !isTrustedBrewfile(url) {
            bundleEntries = []
            bundleCheckStatus = .untrusted
        }
        return url
    }

    func refreshBundle() async {
        guard !isBundleLoading, bundleCheckStatus != .checking else { return }
        lastError = nil
        guard let brewfileURL = resolveBrewfile() else { return }
        guard canExecuteBrewfile(brewfileURL) else { return }
        guard await fetchBundleEntries(brewfileURL: brewfileURL) else { return }
        await checkBundle(brewfileURL: brewfileURL)
    }

    func updateBundleEntryStatuses() {
        guard !bundleEntries.isEmpty else { return }
        bundleEntries = bundleEntries.map {
            BrewBundleEntry(type: $0.type, name: $0.name, status: bundleStatus(for: $0.name, type: $0.type))
        }
    }

    @discardableResult
    func fetchBundleEntries() async -> Bool {
        guard let brewfileURL = resolveBrewfile() else { return false }
        return await fetchBundleEntries(brewfileURL: brewfileURL)
    }

    @discardableResult
    func fetchBundleEntries(brewfileURL: URL) async -> Bool {
        guard canExecuteBrewfile(brewfileURL) else { return false }
        isBundleLoading = true
        defer { isBundleLoading = false }

        var fetchedEntries: [BrewBundleEntry] = []
        for type in BrewBundleEntryType.allCases {
            let arguments = ["bundle", "list", type.listFlag, "--file", brewfileURL.path]
            let result = await runBrewCommand(arguments)
            guard result.success else {
                logger.warning("Failed to list \(type.rawValue) bundle entries: \(result.output.prefix(200))")
                let message = BrewError.commandFailed(
                    command: arguments.joined(separator: " "),
                    output: result.output
                )
                lastError = message
                bundleCheckStatus = .failed(message.localizedDescription)
                bundleEntries = []
                return false
            }
            fetchedEntries += BrewBundleParser.parseList(result.output).map {
                BrewBundleEntry(type: type, name: $0, status: bundleStatus(for: $0, type: type))
            }
        }
        bundleEntries = fetchedEntries
        return true
    }

    func checkBundle() async {
        guard let brewfileURL = resolveBrewfile() else { return }
        await checkBundle(brewfileURL: brewfileURL)
    }

    func checkBundle(brewfileURL: URL) async {
        guard canExecuteBrewfile(brewfileURL) else { return }
        bundleCheckStatus = .checking
        let arguments = ["bundle", "check", "--verbose", "--file", brewfileURL.path]
        let result = await runBrewCommand(arguments)
        let status = BrewBundleParser.parseCheckResult(success: result.success, output: result.output)
        bundleCheckStatus = status

        if case .failed = status {
            logger.warning("Bundle check failed: \(result.output.prefix(200))")
            lastError = .commandFailed(command: arguments.joined(separator: " "), output: result.output)
        }
    }

    /// Overwrites any existing file at `url`; callers must obtain user consent first
    /// (BundleView's NSSavePanel shows the system Replace prompt before calling this).
    @discardableResult
    func dumpBundle(to url: URL) async -> CommandResult {
        guard !isPerformingAction else {
            logger.info("bundle dump skipped, action already in progress")
            return CommandResult(output: "Another action is already running.", success: false)
        }

        isPerformingAction = true
        actionOutput = ""
        lastError = nil

        let arguments = ["bundle", "dump", "--file", url.path]
        let result = await runBrewCommandStreaming(arguments)
        if !result.success, !result.cancelled {
            logger.warning("Bundle dump failed: \(result.output.prefix(200))")
            lastError = .commandFailed(command: arguments.joined(separator: " "), output: result.output)
        }
        recordAction(arguments: arguments, packageName: nil, packageSource: nil, success: result.success, output: result.output)
        isPerformingAction = false

        if result.success {
            customBrewfilePath = url.path
            trustBrewfile(at: url)
            await refreshBundle()
        }
        return result
    }

    @discardableResult
    func trustBrewfile(at url: URL) -> Bool {
        let resolvedURL = url.resolvingSymlinksInPath()
        guard let digest = Self.brewfileDigest(at: resolvedURL) else {
            let message = "Unable to read Brewfile at \(url.path)."
            bundleCheckStatus = .failed(message)
            lastError = .commandFailed(command: "bundle trust", output: message)
            return false
        }
        trustedBrewfilePath = resolvedURL.path
        trustedBrewfileDigest = digest
        if brewfileURL?.path == resolvedURL.path, bundleCheckStatus == .untrusted {
            bundleCheckStatus = .unknown
        }
        return true
    }

    func trustCurrentBrewfileAndRefresh() async {
        guard let brewfileURL = resolveBrewfile() else { return }
        guard trustBrewfile(at: brewfileURL) else { return }
        await refreshBundle()
    }

    private func bundleStatus(for name: String, type: BrewBundleEntryType) -> BrewBundleEntryStatus {
        switch type {
        case .formula:
            return installedFormulae.contains { $0.name == name }
                ? BrewBundleEntryStatus.installed
                : BrewBundleEntryStatus.missing
        case .cask:
            return installedCasks.contains { $0.name == name }
                ? BrewBundleEntryStatus.installed
                : BrewBundleEntryStatus.missing
        case .tap:
            return installedTaps.contains { $0.name == name }
                ? BrewBundleEntryStatus.installed
                : BrewBundleEntryStatus.missing
        case .mas:
            guard isMasAvailable else { return .unknown }
            return installedMasApps.contains { $0.name == name }
                ? BrewBundleEntryStatus.installed
                : BrewBundleEntryStatus.missing
        }
    }

    private func canExecuteBrewfile(_ url: URL) -> Bool {
        guard isTrustedBrewfile(url) else {
            bundleEntries = []
            bundleCheckStatus = .untrusted
            return false
        }
        return true
    }

    private func isTrustedBrewfile(_ url: URL) -> Bool {
        // Homebrew Bundle only accepts a path, so recheck trust immediately before launch.
        guard trustedBrewfilePath == url.path,
              let digest = Self.brewfileDigest(at: url) else {
            return false
        }
        return trustedBrewfileDigest == digest
    }

    private static func brewfileDigest(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
