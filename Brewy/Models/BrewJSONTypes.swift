import Foundation

// MARK: - Brew JSON v2 Response Types

struct BrewInfoResponse: Decodable {
    let formulae: [FormulaJSON]?
    let casks: [CaskJSON]?
}

struct FormulaJSON: Decodable {
    let name: String
    let desc: String?
    let homepage: String?
    let versions: FormulaVersions?
    let pinned: Bool?
    let installed: [FormulaInstalled]?
    let dependencies: [String]?

    struct FormulaVersions: Decodable {
        let stable: String?
    }

    struct FormulaInstalled: Decodable {
        let version: String?
        let installedOnRequest: Bool?

        enum CodingKeys: String, CodingKey {
            case version
            case installedOnRequest = "installed_on_request"
        }
    }

    func toPackage() -> BrewPackage {
        let installedVersion = installed?.first?.version
        let stable = versions?.stable ?? "unknown"
        return BrewPackage(
            id: "formula-\(name)",
            name: name,
            version: installedVersion ?? stable,
            description: desc ?? "",
            homepage: homepage ?? "",
            isInstalled: true,
            isOutdated: false,
            installedVersion: installedVersion,
            latestVersion: stable,
            source: .formula,
            pinned: pinned ?? false,
            installedOnRequest: installed?.first?.installedOnRequest ?? false,
            dependencies: dependencies ?? []
        )
    }
}

struct CaskJSON: Decodable {
    let token: String
    let version: String?
    let installed: String?
    let desc: String?
    let homepage: String?
    let dependencies: [String]

    enum CodingKeys: String, CodingKey {
        case token, version, installed, desc, homepage
        case dependsOn = "depends_on"
    }

    private struct DependsOn: Decodable {
        let formula: [String]?
        let cask: [String]?
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        token = try container.decode(String.self, forKey: .token)
        version = try container.decodeIfPresent(String.self, forKey: .version)
        installed = try container.decodeIfPresent(String.self, forKey: .installed)
        desc = try container.decodeIfPresent(String.self, forKey: .desc)
        homepage = try container.decodeIfPresent(String.self, forKey: .homepage)
        // `depends_on` is usually an object but brew sometimes emits an empty array; tolerate
        // either shape so a cask never fails to decode over its dependency field.
        let deps = try? container.decodeIfPresent(DependsOn.self, forKey: .dependsOn)
        dependencies = (deps?.formula ?? []) + (deps?.cask ?? [])
    }

    func toPackage() -> BrewPackage {
        let latest = version ?? "unknown"
        let installedVersion = installed ?? latest
        return BrewPackage(
            id: "cask-\(token)",
            name: token,
            version: installedVersion,
            description: desc ?? "",
            homepage: homepage ?? "",
            isInstalled: true,
            isOutdated: false,
            installedVersion: installedVersion,
            latestVersion: latest,
            source: .cask,
            pinned: false,
            installedOnRequest: true,
            dependencies: dependencies
        )
    }
}

struct BrewOutdatedResponse: Decodable {
    let formulae: [OutdatedFormulaJSON]?
    let casks: [OutdatedCaskJSON]?
}

struct OutdatedFormulaJSON: Decodable {
    let name: String
    let installedVersions: [String]?
    let currentVersion: String?
    let pinned: Bool?

    enum CodingKeys: String, CodingKey {
        case name
        case installedVersions = "installed_versions"
        case currentVersion = "current_version"
        case pinned
    }

    func toPackage() -> BrewPackage? {
        guard let currentVersion else { return nil }
        return BrewPackage(
            id: "formula-\(name)",
            name: name,
            version: installedVersions?.first ?? "unknown",
            description: "",
            homepage: "",
            isInstalled: true,
            isOutdated: true,
            installedVersion: installedVersions?.first,
            latestVersion: currentVersion,
            source: .formula,
            pinned: pinned ?? false,
            installedOnRequest: true,
            dependencies: []
        )
    }
}

struct OutdatedCaskJSON: Decodable {
    let name: String
    let installedVersions: [String]?
    let currentVersion: String?

    enum CodingKeys: String, CodingKey {
        case name
        case installedVersions = "installed_versions"
        case currentVersion = "current_version"
    }

    func toPackage() -> BrewPackage? {
        guard let currentVersion,
              let installedVersion = installedVersions?.first else { return nil }
        return BrewPackage(
            id: "cask-\(name)",
            name: name,
            version: installedVersion,
            description: "",
            homepage: "",
            isInstalled: true,
            isOutdated: true,
            installedVersion: installedVersion,
            latestVersion: currentVersion,
            source: .cask,
            pinned: false,
            installedOnRequest: true,
            dependencies: []
        )
    }
}

struct TapJSON: Decodable {
    let name: String
    let remote: String?
    let official: Bool?
    let formulaNames: [String]?
    let caskTokens: [String]?

    enum CodingKeys: String, CodingKey {
        case name
        case remote
        case official
        case formulaNames = "formula_names"
        case caskTokens = "cask_tokens"
    }

    func toTap() -> BrewTap {
        var resolvedRemote = remote ?? ""
        if resolvedRemote.hasSuffix(".git") { resolvedRemote = String(resolvedRemote.dropLast(4)) }
        return BrewTap(
            name: name,
            remote: resolvedRemote,
            isOfficial: official ?? false,
            formulaNames: formulaNames ?? [],
            caskTokens: caskTokens ?? []
        )
    }
}
