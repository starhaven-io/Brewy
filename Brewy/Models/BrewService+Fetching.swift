import Foundation
import OSLog

private let logger = Logger(subsystem: "io.linnane.brewy", category: "BrewService+Fetching")

struct InstalledBrewPackages {
    let formulae: [BrewPackage]
    let casks: [BrewPackage]
    let applicationURLs: [String: URL]
}

struct MergedRefreshPackages {
    let formulae: [BrewPackage]
    let casks: [BrewPackage]
    let masApps: [BrewPackage]
    let outdated: [BrewPackage]

    var installedIDs: Set<String> {
        Set((formulae + casks + masApps).map(\.id))
    }
}

extension BrewService {

    nonisolated static func mergeRefreshPackages(
        formulae: [BrewPackage],
        casks: [BrewPackage],
        masApps: [BrewPackage],
        outdated: [BrewPackage]
    ) -> MergedRefreshPackages {
        let outdatedByID = Dictionary(outdated.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let formulae = formulae.map { mergeOutdatedStatus($0, outdatedByID: outdatedByID) }
        let casks = casks.map { mergeOutdatedStatus($0, outdatedByID: outdatedByID) }
        let masApps = masApps.map { mergeOutdatedStatus($0, outdatedByID: outdatedByID) }
        let mergedByID = Dictionary(
            (formulae + casks + masApps).filter(\.isOutdated).map { ($0.id, $0) },
            uniquingKeysWith: { _, last in last }
        )
        return MergedRefreshPackages(
            formulae: formulae,
            casks: casks,
            masApps: masApps,
            outdated: outdated.map { mergedByID[$0.id] ?? $0 }
        )
    }

    // MARK: - Fetch Installed Packages

    /// Returns `nil` when the brew command fails so the caller can keep the previously loaded lists
    /// instead of clobbering them to empty; a successful-but-empty response still returns `[]`s.
    /// One `brew info --installed --json=v2` invocation carries both formulae and casks in the
    /// JSON v2 envelope, so a refresh needs a single pass over the installed set, not two.
    func fetchInstalledPackages() async -> InstalledBrewPackages? {
        let result = await runBrewCommand(["info", "--installed", "--json=v2"])
        guard result.success, let data = result.output.data(using: .utf8) else {
            if !result.success {
                reportFetchError(command: "info --installed", output: result.output)
            }
            return result.success ? InstalledBrewPackages(formulae: [], casks: [], applicationURLs: [:]) : nil
        }

        let packages: InstalledBrewPackages? = await Task.detached(priority: .userInitiated) {
            do {
                let response = try JSONDecoder().decode(BrewInfoResponse.self, from: data)
                let casks = response.casks ?? []
                let applicationURLs = Dictionary(
                    casks.compactMap { cask in
                        cask.applicationBundleURLs.first.map { ("cask-\(cask.token)", $0) }
                    },
                    uniquingKeysWith: { _, latest in latest }
                )
                return InstalledBrewPackages(
                    formulae: (response.formulae ?? []).map { $0.toPackage() },
                    casks: casks.map { $0.toPackage() },
                    applicationURLs: applicationURLs
                )
            } catch {
                logger.error("Failed to parse installed packages JSON: \(error.localizedDescription)")
                return nil
            }
        }.value
        if packages == nil {
            reportFetchError(command: "info --installed --json=v2", output: "Failed to parse Homebrew packages JSON.")
        }
        return packages
    }

    func fetchOutdatedPackages() async -> [BrewPackage]? {
        let result = await runBrewCommand(["outdated", "--json=v2"])
        guard result.success, let data = result.output.data(using: .utf8) else {
            if !result.success {
                reportFetchError(command: "outdated", output: result.output)
            }
            return result.success ? [] : nil
        }

        let packages: [BrewPackage]? = await Task.detached(priority: .userInitiated) { () -> [BrewPackage]? in
            do {
                let response = try JSONDecoder().decode(BrewOutdatedResponse.self, from: data)
                let formulae = (response.formulae ?? []).compactMap { $0.toPackage() }
                let casks = (response.casks ?? []).compactMap { $0.toPackage() }
                return formulae + casks
            } catch {
                logger.error("Failed to parse outdated JSON: \(error.localizedDescription)")
                return nil
            }
        }.value
        if packages == nil {
            reportFetchError(command: "outdated --json=v2", output: "Failed to parse Homebrew outdated JSON.")
        }
        return packages
    }

    func fetchTaps() async -> [BrewTap]? {
        let result = await runBrewCommand(["tap-info", "--json=v1", "--installed"])
        guard result.success, let data = result.output.data(using: .utf8) else {
            if !result.success {
                reportFetchError(command: "tap-info", output: result.output)
            }
            return result.success ? [] : nil
        }

        let taps: [BrewTap]? = await Task.detached(priority: .userInitiated) { () -> [BrewTap]? in
            do {
                let taps = try JSONDecoder().decode([TapJSON].self, from: data)
                return taps.map { $0.toTap() }
            } catch {
                logger.error("Failed to parse taps JSON: \(error.localizedDescription)")
                return nil
            }
        }.value
        if taps == nil {
            reportFetchError(command: "tap-info --json=v1 --installed", output: "Failed to parse Homebrew taps JSON.")
        }
        return taps
    }

    // MARK: - Search

    func performSearch(query: String) async -> [BrewPackage] {
        async let formulaeResult = runBrewCommand(["search", "--formula", "--", query])
        async let casksResult = runBrewCommand(["search", "--cask", "--", query])

        let formulaeOutput = await formulaeResult
        let casksOutput = await casksResult

        // Match on source-qualified IDs, not bare names: a cask hit named like an
        // installed formula (e.g. wireshark) must not show the installed badge.
        let knownIDs = installedIDs
        var packages: [BrewPackage] = []

        for output in [(formulaeOutput, PackageSource.formula), (casksOutput, PackageSource.cask)] {
            let (result, source) = output
            guard result.success else { continue }

            let prefix = source == .cask ? "cask" : "formula"
            for line in result.output.split(separator: "\n") {
                // Skip section headers like "==> Formulae" / "==> Casks" wholesale; otherwise the
                // header word ("Formulae"/"Casks") survives tokenization as a phantom package.
                if line.hasPrefix("==>") { continue }
                for token in line.split(whereSeparator: \.isWhitespace) {
                    let name = String(token)
                    packages.append(BrewPackage(
                        id: "\(prefix)-search-\(name)",
                        name: name,
                        version: "",
                        description: "",
                        homepage: "",
                        isInstalled: knownIDs.contains("\(prefix)-\(name)"),
                        isOutdated: false,
                        installedVersion: nil,
                        latestVersion: nil,
                        source: source,
                        pinned: false,
                        installedOnRequest: false,
                        dependencies: []
                    ))
                }
            }
        }

        return packages
    }
}
