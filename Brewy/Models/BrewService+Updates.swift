import Foundation
import OSLog

private let logger = Logger(subsystem: "io.linnane.brewy", category: "BrewService+Updates")

// MARK: - Homebrew Update Tracking

extension BrewService {

    nonisolated static let lastUpdateResultURL: URL? = cacheDirectory?.appendingPathComponent("lastUpdateResult.json")

    // MARK: - Run

    func updateHomebrew() async {
        guard !isPerformingAction else {
            logger.info("updateHomebrew skipped, action already in progress")
            return
        }
        isPerformingAction = true
        actionOutput = ""
        lastError = nil
        defer { isPerformingAction = false }

        let arguments = ["update"]
        let result = await runBrewCommand(arguments)
        actionOutput = result.output

        if !result.success {
            lastError = .commandFailed(command: "update", output: result.output)
        } else {
            let parsed = BrewUpdateParser.parse(result.output)
            lastUpdateResult = parsed
            saveLastUpdateResult()
            logger.info("Update parsed: \(parsed.newFormulae.count) new formulae, \(parsed.newCasks.count) new casks")
        }

        recordAction(arguments: arguments, packageName: nil, packageSource: nil, success: result.success, output: result.output)
        await refresh()
    }

    // MARK: - Persistence

    func loadLastUpdateResult() {
        guard let url = Self.lastUpdateResultURL else { return }
        do {
            let data = try Data(contentsOf: url)
            lastUpdateResult = try JSONDecoder().decode(BrewUpdateResult.self, from: data)
            logger.info("Loaded last update result with \(self.lastUpdateResult?.totalCount ?? 0) new packages")
        } catch CocoaError.fileReadNoSuchFile {
            // no prior update saved yet — normal on first launch
        } catch {
            logger.warning("Failed to load last update result: \(error.localizedDescription)")
        }
    }

    private func saveLastUpdateResult() {
        guard let url = Self.lastUpdateResultURL,
              ProcessInfo.processInfo.environment["XCTestBundlePath"] == nil,
              let result = lastUpdateResult else { return }
        Task.detached(priority: .utility) {
            do {
                let data = try JSONEncoder().encode(result)
                try data.write(to: url, options: .atomic)
                logger.debug("Last update result saved")
            } catch {
                logger.error("Failed to save last update result: \(error.localizedDescription)")
            }
        }
    }
}
