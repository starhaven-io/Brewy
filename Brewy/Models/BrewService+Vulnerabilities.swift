import Foundation

extension BrewService {
    func scanVulnerabilities() async {
        guard !isScanningVulnerabilities else { return }
        isScanningVulnerabilities = true
        vulnerabilityScanError = nil
        defer { isScanningVulnerabilities = false }
        var formulaFingerprint = installedFormulaFingerprint

        var result = await runBrewCommand(["vulns", "--json"])
        guard !result.cancelled else { return }
        if formulaFingerprint != installedFormulaFingerprint {
            formulaFingerprint = installedFormulaFingerprint
            result = await runBrewCommand(["vulns", "--json"])
            guard !result.cancelled else { return }
        }
        guard formulaFingerprint == installedFormulaFingerprint else { return }

        guard result.exitCode == nil || result.exitCode == 0 || result.exitCode == 1 else {
            vulnerabilityScanError = .commandFailed(command: "vulns --json", output: result.output)
            return
        }

        do {
            let report = try JSONDecoder().decode(
                BrewVulnerabilityReport.self,
                from: Data(result.standardOutput.utf8)
            )
            vulnerabilityScan = FormulaVulnerabilityScan(
                findings: report.findings,
                scannedAt: Date(),
                warning: Self.nonemptyVulnerabilityMessage(result.standardError),
                skippedFormulae: report.skippedFormulae
            )
        } catch {
            vulnerabilityScanError = .commandFailed(command: "vulns --json", output: result.output)
        }
    }

    private static func nonemptyVulnerabilityMessage(_ output: String) -> String? {
        let message = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? nil : message
    }
}
