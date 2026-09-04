import Foundation
import OSLog

private let logger = Logger(subsystem: "io.linnane.brewy", category: "ServicesService")

// MARK: - Services Parser

enum ServicesParser {

    static func parseJSON(_ output: String) -> [BrewServiceItem] {
        (try? decodeJSON(output)) ?? []
    }

    static func decodeJSON(_ output: String) throws -> [BrewServiceItem] {
        guard let data = output.data(using: .utf8) else { return [] }
        do {
            return try JSONDecoder().decode([BrewServiceItem].self, from: data)
        } catch {
            logger.error("Failed to parse services JSON: \(error.localizedDescription)")
            throw error
        }
    }
}

struct ServicesFetchError: LocalizedError {
    let commandOutput: String

    var errorDescription: String? {
        let output = UTF8ByteTruncation.prefix(
            commandOutput.trimmingCharacters(in: .whitespacesAndNewlines),
            maxBytes: 4_096
        )
        return output.isEmpty
            ? "Homebrew did not return valid service data."
            : "Homebrew could not load services.\n\(output)"
    }
}

// MARK: - BrewService Services Integration

extension BrewService {

    func fetchServices() async throws -> [BrewServiceItem] {
        let brewPath = CommandRunner.resolvedBrewPath(preferred: customBrewPath)

        let infoResult = await commandRunner.run(["services", "info", "--all", "--json"], brewPath: brewPath)
        let infoServices: [BrewServiceItem]?
        if infoResult.success {
            infoServices = try? ServicesParser.decodeJSON(infoResult.output)
            if let infoServices, !infoServices.isEmpty { return infoServices }
        } else {
            infoServices = nil
        }

        let listResult = await commandRunner.run(["services", "list", "--json"], brewPath: brewPath)
        guard listResult.success else {
            if let infoServices { return infoServices }
            let output = listResult.output.isEmpty ? infoResult.output : listResult.output
            logger.warning("Failed to fetch services: \(output.prefix(200))")
            throw ServicesFetchError(commandOutput: output)
        }
        do {
            return try ServicesParser.decodeJSON(listResult.output)
        } catch {
            logger.warning("Homebrew returned invalid services JSON: \(error.localizedDescription)")
            throw ServicesFetchError(commandOutput: "Homebrew returned invalid service data.")
        }
    }

    func startService(_ name: String) async -> CommandResult {
        await runServiceCommand(["services", "start", name])
    }

    func stopService(_ name: String) async -> CommandResult {
        await runServiceCommand(["services", "stop", name])
    }

    func restartService(_ name: String) async -> CommandResult {
        await runServiceCommand(["services", "restart", name])
    }

    func cleanupServices() async -> CommandResult {
        let brewPath = CommandRunner.resolvedBrewPath(preferred: customBrewPath)
        let result = await commandRunner.run(["services", "cleanup"], brewPath: brewPath)
        if !result.success {
            logger.warning("Services cleanup failed: \(result.output.prefix(200))")
        }
        return result
    }

    private func runServiceCommand(_ arguments: [String]) async -> CommandResult {
        let brewPath = CommandRunner.resolvedBrewPath(preferred: customBrewPath)
        return await commandRunner.run(arguments, brewPath: brewPath)
    }
}
