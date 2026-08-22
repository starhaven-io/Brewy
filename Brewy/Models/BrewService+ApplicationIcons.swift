import Foundation

extension BrewService {

    func installedApplicationURL(for package: BrewPackage) -> URL? {
        if let url = installedApplicationURLs[package.id] {
            return url
        }
        guard package.isInstalled, package.isCask else { return nil }
        return installedApplicationURLs["cask-\(package.name)"]
    }

    nonisolated static func refreshedApplicationURLs(
        existingURLs: [String: URL],
        brewURLs: [String: URL]?,
        masURLs: [String: URL]?,
        installedIDs: Set<String>
    ) -> [String: URL] {
        var urls = existingURLs
        if let brewURLs {
            urls = urls.filter { !$0.key.hasPrefix("cask-") }
            urls.merge(brewURLs, uniquingKeysWith: { _, latest in latest })
        }
        if let masURLs {
            urls = urls.filter { !$0.key.hasPrefix("mas-") }
            urls.merge(masURLs, uniquingKeysWith: { _, latest in latest })
        }
        return urls.filter { installedIDs.contains($0.key) }
    }
}
