// Compiled standalone in CI (with BrewJSONTypes.swift, PackageModel.swift, and
// ExternalURLPolicy.swift) and run against the runner's real Homebrew to catch
// upstream JSON schema drift before users hit it. See .github/workflows/brew-json-probe.yml.
import Foundation

struct ProbeFailure: Error, CustomStringConvertible {
    let description: String
}

func runBrew(_ arguments: [String]) throws -> Data {
    let standardBrewPaths = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
    guard let brewPath = standardBrewPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
        throw ProbeFailure(description: "brew not found at \(standardBrewPaths.joined(separator: " or "))")
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: brewPath)
    process.arguments = arguments
    let stdout = Pipe()
    process.standardOutput = stdout
    try process.run()
    // Drain to EOF before waiting so a full pipe can't deadlock the child.
    let output = stdout.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw ProbeFailure(description: "brew \(arguments.joined(separator: " ")) exited \(process.terminationStatus)")
    }
    return output
}

func probe() throws {
    // The app's refresh contract: one `info --installed` call carries both arrays.
    let installedData = try runBrew(["info", "--installed", "--json=v2"])
    let installed = try JSONDecoder().decode(BrewInfoResponse.self, from: installedData)
    let formulae = (installed.formulae ?? []).map { $0.toPackage() }
    let casks = (installed.casks ?? []).map { $0.toPackage() }
    print("installed envelope: \(formulae.count) formulae, \(casks.count) casks decoded")
    guard !formulae.isEmpty else {
        throw ProbeFailure(description: "no installed formulae decoded; the workflow installs one before probing")
    }
    guard !casks.isEmpty else {
        throw ProbeFailure(description: "no installed casks decoded; the workflow installs one before probing")
    }

    // Decode additional live cask metadata without installing large applications.
    let caskData = try runBrew(["info", "--json=v2", "--cask", "--", "firefox", "iterm2"])
    let caskInfo = try JSONDecoder().decode(BrewInfoResponse.self, from: caskData)
    let probedCasks = (caskInfo.casks ?? []).map { $0.toPackage() }
    print("cask metadata: \(probedCasks.count) casks decoded")
    guard probedCasks.count == 2 else {
        throw ProbeFailure(description: "expected 2 casks decoded, got \(probedCasks.count)")
    }

    let outdatedData = try runBrew(["outdated", "--json=v2"])
    let outdated = try JSONDecoder().decode(BrewOutdatedResponse.self, from: outdatedData)
    let outdatedCount = (outdated.formulae?.count ?? 0) + (outdated.casks?.count ?? 0)
    print("outdated envelope decoded (\(outdatedCount) entries)")

    let tapData = try runBrew(["tap-info", "--json=v1", "--installed"])
    let taps = try JSONDecoder().decode([TapJSON].self, from: tapData).map { $0.toTap() }
    print("tap-info envelope decoded (\(taps.count) taps)")
}

do {
    try probe()
    print("brew JSON drift probe passed")
} catch {
    print("brew JSON drift probe FAILED: \(error)")
    exit(1)
}
