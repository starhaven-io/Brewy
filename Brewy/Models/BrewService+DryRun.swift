import Darwin
import Foundation

struct BrewCommandPreview {
    let result: CommandResult
    fileprivate let arguments: [String]
    fileprivate let installation: PreviewInstallation?

    var executablePath: String? { installation?.executablePath }
}

private struct PreviewInstallation: Equatable {
    let configuredPath: String?
    let executablePath: String
    let targetPath: String
    let device: dev_t
    let inode: ino_t

    init?(configuredPath: String?, defaultPath: String) {
        self.configuredPath = configuredPath
        if let configuredPath, !configuredPath.isEmpty {
            executablePath = configuredPath
        } else {
            executablePath = CommandRunner.resolvedBrewPath(preferred: defaultPath)
        }
        var attributes = stat()
        guard CommandRunner.isRegularExecutable(atPath: executablePath), stat(executablePath, &attributes) == 0 else { return nil }
        // Preserve the invocation path: Homebrew also derives its prefix from the directory containing the symlink.
        targetPath = URL(fileURLWithPath: executablePath).resolvingSymlinksInPath().path
        device = attributes.st_dev
        inode = attributes.st_ino
    }
}

extension BrewService {
    private var previewInstallation: PreviewInstallation? {
        PreviewInstallation(configuredPath: preferences.string(forKey: "brewPath"), defaultPath: customBrewPath)
    }

    func previewRetry(_ entry: ActionHistoryEntry) async -> BrewCommandPreview {
        guard entry.isRetryable, let arguments = entry.retryPreviewArguments else {
            let failure = CommandResult(output: "This command does not support a retry preview.", success: false)
            return BrewCommandPreview(result: failure, arguments: entry.arguments, installation: nil)
        }
        return await previewCommand(entry.arguments, dryRunArguments: arguments)
    }

    func dryRunAutoremove() async -> BrewCommandPreview {
        await previewCommand(["autoremove"], dryRunArguments: ["autoremove", "--dry-run"])
    }

    func dryRunCleanup() async -> BrewCommandPreview {
        let arguments = ["cleanup", "--prune=all", "-s"]
        return await previewCommand(arguments, dryRunArguments: arguments + ["--dry-run"])
    }

    private func previewCommand(_ arguments: [String], dryRunArguments: [String]) async -> BrewCommandPreview {
        guard let installation = previewInstallation else {
            let failure = CommandResult(output: "The selected Homebrew executable is unavailable. Check Homebrew Path in Settings.", success: false)
            return BrewCommandPreview(result: failure, arguments: arguments, installation: nil)
        }
        let result = await commandRunner.run(dryRunArguments, brewPath: installation.executablePath,
                                             timeout: CommandRunner.timeout(forBrewArguments: dryRunArguments))
        return BrewCommandPreview(result: result, arguments: arguments, installation: installation)
    }

    func confirmedBrewPath(for preview: BrewCommandPreview, arguments: [String]) -> String? {
        guard preview.result.success, !preview.result.cancelled, preview.arguments == arguments,
              let installation = preview.installation, installation == previewInstallation else {
            lastError = .commandFailed(command: arguments.first ?? "cleanup", output: "Run a new preview for the current Homebrew installation.")
            return nil
        }
        return installation.executablePath
    }
}
