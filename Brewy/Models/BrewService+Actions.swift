import Foundation
import OSLog

private let logger = Logger(subsystem: "io.linnane.brewy", category: "BrewService+Actions")

extension BrewService {

    // MARK: - Package Actions

    func install(package: BrewPackage) async {
        await performAction("install", package: package)
    }

    func uninstall(package: BrewPackage) async {
        await performAction("uninstall", package: package)
    }

    func upgrade(package: BrewPackage) async {
        await performAction("upgrade", package: package)
    }

    func upgradeAll() async {
        let masOutdatedCount = outdatedPackages.filter(\.isMas).count
        await performBrewAction(["upgrade"], refreshAfter: true)
        if masOutdatedCount > 0, lastError == nil {
            lastError = .commandFailed(command: "upgrade", output: Self.masUpgradeMessage(count: masOutdatedCount))
        }
    }

    func pin(package: BrewPackage) async { await performAction("pin", package: package) }
    func unpin(package: BrewPackage) async { await performAction("unpin", package: package) }
    func reinstall(package: BrewPackage) async { await performAction("reinstall", package: package) }
    func fetch(package: BrewPackage) async { await performAction("fetch", package: package) }
    func link(package: BrewPackage) async { await performAction("link", package: package) }
    func unlink(package: BrewPackage) async { await performAction("unlink", package: package) }

    // MARK: - Action Helpers

    func performBrewAction(_ arguments: [String], refreshAfter: Bool = false) async {
        guard !isPerformingAction else {
            logger.info("\(arguments.first ?? "action") skipped, action already in progress")
            return
        }
        isPerformingAction = true
        actionOutput = ""
        lastError = nil
        defer { isPerformingAction = false }

        let result = await runBrewCommand(arguments)
        actionOutput = result.output
        if !result.success {
            lastError = .commandFailed(command: arguments.joined(separator: " "), output: result.output)
        }
        recordAction(arguments: arguments, packageName: nil, packageSource: nil, success: result.success, output: result.output)
        if refreshAfter {
            await refresh()
        }
    }

    func performAction(_ action: String, package: BrewPackage) async {
        guard !package.isMas else {
            logger.warning("Cannot perform brew action \(action) on mas package \(package.name)")
            lastError = .commandFailed(
                command: action,
                output: "Mac App Store apps are managed outside Homebrew. Open the App Store to update \(package.name)."
            )
            return
        }
        guard !isPerformingAction else {
            logger.info("\(action) on \(package.name) skipped, action already in progress")
            return
        }
        logger.info("Performing \(action) on \(package.name)")
        isPerformingAction = true
        actionOutput = ""
        lastError = nil
        defer { isPerformingAction = false }

        var args = [action]
        if package.isCask { args.append("--cask") }
        args.append("--")
        args.append(package.name)

        let result = await runBrewCommand(args)
        actionOutput = result.output
        if !result.success {
            logger.warning("\(action) failed for \(package.name): \(result.output.prefix(200))")
            lastError = .commandFailed(command: action, output: result.output)
        }
        recordAction(
            arguments: args,
            packageName: package.name,
            packageSource: package.source,
            success: result.success,
            output: result.output
        )
        await refresh()
    }

    // MARK: - Maintenance

    func doctor() async -> String {
        let result = await runBrewCommand(["doctor"])
        recordAction(arguments: ["doctor"], packageName: nil, packageSource: nil, success: result.success, output: result.output)
        return result.output
    }

    func removeOrphans() async {
        await performBrewAction(["autoremove"], refreshAfter: true)
    }

    func cacheSize() async -> Int64 {
        let pathResult = await runBrewCommand(["--cache"])
        let cachePath = pathResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cachePath.isEmpty else { return 0 }

        let result = await commandRunner.runExecutable("/usr/bin/du", arguments: ["-sk", cachePath])
        guard result.success,
              let sizeStr = result.output.split(separator: "\t").first,
              let sizeKB = Int64(sizeStr) else {
            return 0
        }
        return sizeKB * 1_024
    }

    func purgeCache() async {
        await performBrewAction(["cleanup", "--prune=all", "-s"])
    }

    func config() async -> BrewConfig {
        let result = await runBrewCommand(["config"])
        return BrewConfig.parse(from: result.output)
    }

    func info(for package: BrewPackage) async -> String {
        guard !package.isMas else { return "" }
        if let cached = infoCache[package.id] { return cached }
        let command = package.isCask ? ["info", "--cask", "--", package.name] : ["info", "--", package.name]
        let result = await runBrewCommand(command)
        // Don't cache failures: a transient error would otherwise stick until the version changes.
        if result.success {
            infoCache[package.id] = result.output
        }
        return result.output
    }

    static func masUpgradeMessage(count: Int) -> String {
        if count == 1 {
            return "1 Mac App Store app must be updated in the App Store."
        }
        return "\(count) Mac App Store apps must be updated in the App Store."
    }
}
