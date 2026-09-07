import Foundation
import OSLog

private let logger = Logger(subsystem: "io.linnane.brewy", category: "BrewService+PackageDetail")

// MARK: - Package Detail Fetching

extension BrewService {

    func fetchPackageDetail(for package: BrewPackage) async -> BrewPackage? {
        let command = package.isCask
            ? ["info", "--cask", "--json=v2", "--", package.name]
            : ["info", "--json=v2", "--", package.name]
        let result = await runBrewCommand(command)
        guard result.success, let data = result.output.data(using: .utf8) else { return nil }

        return await Task.detached(priority: .userInitiated) {
            do {
                let response = try JSONDecoder().decode(BrewInfoResponse.self, from: data)
                if package.isCask, let cask = response.casks?.first {
                    return BrewPackage(
                        id: package.id,
                        name: cask.token,
                        version: cask.version ?? package.version,
                        description: cask.desc ?? package.description,
                        homepage: cask.homepage ?? package.homepage,
                        isInstalled: package.isInstalled,
                        isOutdated: package.isOutdated,
                        installedVersion: package.installedVersion,
                        latestVersion: package.latestVersion,
                        source: package.source,
                        pinned: package.pinned,
                        installedOnRequest: package.installedOnRequest,
                        dependencies: cask.dependencies,
                        dependencyReferences: cask.dependencyReferences,
                        repositoryURL: cask.repositoryURL ?? (cask.url == nil ? package.repositoryURL : nil)
                    )
                }
                if let formula = response.formulae?.first {
                    return BrewPackage(
                        id: package.id,
                        name: formula.name,
                        version: formula.versions?.stable ?? package.version,
                        description: formula.desc ?? package.description,
                        homepage: formula.homepage ?? package.homepage,
                        isInstalled: package.isInstalled,
                        isOutdated: package.isOutdated,
                        installedVersion: package.installedVersion,
                        latestVersion: package.latestVersion,
                        source: package.source,
                        pinned: package.pinned,
                        installedOnRequest: package.installedOnRequest,
                        dependencies: formula.dependencies ?? package.dependencies,
                        dependencyReferences: formula.dependencies.map {
                            $0.map { PackageReference(name: $0, source: .formula) }
                        } ?? package.dependencyReferences,
                        repositoryURL: package.repositoryURL
                    )
                }
                return nil
            } catch {
                logger.error("Failed to parse package detail JSON for \(package.name): \(error.localizedDescription)")
                return nil
            }
        }.value
    }
}

// Fetched description/dependency metadata must not replace newer installed/pinned state.
extension BrewPackage {
    func enriched(with metadata: BrewPackage?) -> BrewPackage {
        guard let metadata, metadata.id == id else { return self }
        return BrewPackage(
            id: id, name: name, version: isInstalled ? version : metadata.version,
            description: metadata.description, homepage: metadata.homepage,
            isInstalled: isInstalled, isOutdated: isOutdated,
            installedVersion: installedVersion, latestVersion: latestVersion,
            source: source, pinned: pinned, installedOnRequest: installedOnRequest,
            dependencies: metadata.dependencies, dependencyReferences: metadata.dependencyReferences,
            repositoryURL: metadata.repositoryURL
        )
    }
}
