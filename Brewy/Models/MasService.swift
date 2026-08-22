import Foundation
import OSLog

private let logger = Logger(subsystem: "io.linnane.brewy", category: "MasService")

struct MasInstalledAppsResult {
    let packages: [BrewPackage]
    let applicationURLs: [String: URL]
}

// MARK: - Mas Output Parser

enum MasParser {

    private struct InstalledAppJSON: Decodable {
        let adamID: Int
        let name: String
        let path: String
        let version: String

        private enum CodingKeys: String, CodingKey {
            case adamID, name, path, version
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            adamID = try container.decode(Int.self, forKey: .adamID)
            name = try container.decode(String.self, forKey: .name)
            path = try container.decodeIfPresent(String.self, forKey: .path) ?? ""
            version = try container.decodeIfPresent(String.self, forKey: .version) ?? ""
        }
    }

    static func parseJSONList(_ output: String) -> MasInstalledAppsResult? {
        let lines = output.split(whereSeparator: \.isNewline)
        guard !lines.isEmpty else {
            return MasInstalledAppsResult(packages: [], applicationURLs: [:])
        }

        let records = lines.compactMap { line in
            try? JSONDecoder().decode(InstalledAppJSON.self, from: Data(line.utf8))
        }
        guard !records.isEmpty else { return nil }

        let packages = records.map { record in
            makePackage(appID: String(record.adamID), name: record.name, version: record.version)
        }
        let applicationURLPairs: [(String, URL)] = zip(packages, records).compactMap { pair in
            let (package, record) = pair
            let url = URL(fileURLWithPath: record.path)
            guard url.pathExtension.caseInsensitiveCompare("app") == .orderedSame else { return nil }
            return (package.id, url)
        }
        let applicationURLs = Dictionary(
            applicationURLPairs,
            uniquingKeysWith: { _, latest in latest }
        )
        return MasInstalledAppsResult(packages: packages, applicationURLs: applicationURLs)
    }

    static func parseList(_ output: String) -> [BrewPackage] {
        var packages: [BrewPackage] = []
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            guard let firstSpace = trimmed.firstIndex(of: " ") else { continue }
            let appId = String(trimmed[trimmed.startIndex..<firstSpace])
            guard Int(appId) != nil else { continue }

            let rest = trimmed[trimmed.index(after: firstSpace)...].trimmingCharacters(in: .whitespaces)

            var name = rest
            var version = "unknown"
            if let parenOpen = rest.lastIndex(of: "("),
               let parenClose = rest.lastIndex(of: ")"),
               parenClose > parenOpen {
                name = rest[rest.startIndex..<parenOpen].trimmingCharacters(in: .whitespaces)
                version = String(rest[rest.index(after: parenOpen)..<parenClose])
            }

            packages.append(makePackage(appID: appId, name: name, version: version))
        }
        return packages
    }

    private static func makePackage(appID: String, name: String, version: String) -> BrewPackage {
        let uniqueId = appID == "0" ? "mas-0-\(name)" : "mas-\(appID)"
        return BrewPackage(
            id: uniqueId,
            name: name,
            version: version,
            description: "",
            homepage: appID == "0" ? "" : "https://apps.apple.com/app/id\(appID)",
            isInstalled: true,
            isOutdated: false,
            installedVersion: version,
            latestVersion: nil,
            source: .mas,
            pinned: false,
            installedOnRequest: true,
            dependencies: []
        )
    }

    static func parseOutdated(_ output: String) -> [BrewPackage] {
        var packages: [BrewPackage] = []
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            guard let firstSpace = trimmed.firstIndex(of: " ") else { continue }
            let appId = String(trimmed[trimmed.startIndex..<firstSpace])
            guard Int(appId) != nil else { continue }

            let rest = trimmed[trimmed.index(after: firstSpace)...].trimmingCharacters(in: .whitespaces)

            var name = rest
            var installedVersion = "unknown"
            var latestVersion = "unknown"
            if let parenOpen = rest.lastIndex(of: "("),
               let parenClose = rest.lastIndex(of: ")"),
               parenClose > parenOpen {
                name = rest[rest.startIndex..<parenOpen].trimmingCharacters(in: .whitespaces)
                let versionStr = String(rest[rest.index(after: parenOpen)..<parenClose])
                let parts = versionStr.components(separatedBy: "->").map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                if parts.count == 2 {
                    installedVersion = parts[0]
                    latestVersion = parts[1]
                } else {
                    installedVersion = versionStr
                    latestVersion = versionStr
                }
            }

            let uniqueId = appId == "0" ? "mas-0-\(name)" : "mas-\(appId)"
            packages.append(BrewPackage(
                id: uniqueId,
                name: name,
                version: installedVersion,
                description: "",
                homepage: appId == "0" ? "" : "https://apps.apple.com/app/id\(appId)",
                isInstalled: true,
                isOutdated: true,
                installedVersion: installedVersion,
                latestVersion: latestVersion,
                source: .mas,
                pinned: false,
                installedOnRequest: true,
                dependencies: []
            ))
        }
        return packages
    }
}

// MARK: - BrewService Mas Integration

extension BrewService {

    func fetchInstalledMasApps() async -> MasInstalledAppsResult? {
        let executablePath = masExecutablePath
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            isMasAvailable = false
            return MasInstalledAppsResult(packages: [], applicationURLs: [:])
        }
        isMasAvailable = true

        let jsonResult = await commandRunner.runExecutable(executablePath, arguments: ["list", "--json"])
        if jsonResult.success, let parsed = MasParser.parseJSONList(jsonResult.standardOutput) {
            return parsed
        }

        let result = await commandRunner.runExecutable(executablePath, arguments: ["list"])
        guard result.success else {
            logger.warning("Failed to fetch installed mas apps")
            return nil
        }
        if let parsed = MasParser.parseJSONList(result.standardOutput) {
            return parsed
        }
        let packages = MasParser.parseList(result.standardOutput)
        guard !packages.isEmpty || result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            logger.warning("Failed to parse installed mas apps")
            return nil
        }
        return MasInstalledAppsResult(packages: packages, applicationURLs: [:])
    }

    func fetchOutdatedMasApps() async -> [BrewPackage]? {
        let executablePath = masExecutablePath
        guard FileManager.default.isExecutableFile(atPath: executablePath) else { return [] }

        let result = await commandRunner.runExecutable(executablePath, arguments: ["outdated"])
        guard result.success else {
            logger.warning("Failed to fetch outdated mas apps")
            return nil
        }
        return MasParser.parseOutdated(result.output)
    }

    func installMas() async {
        guard !isPerformingAction else {
            logger.info("installMas skipped, action already in progress")
            return
        }
        logger.info("Installing mas via Homebrew")
        isPerformingAction = true
        actionOutput = ""
        lastError = nil
        defer { isPerformingAction = false }

        let result = await runBrewCommandStreaming(["install", "mas"])
        if result.success {
            isMasAvailable = true
            await refresh()
        } else if !result.cancelled {
            lastError = .commandFailed(command: "install mas", output: result.output)
        }
    }
}
