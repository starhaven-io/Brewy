import Foundation

enum HomebrewAnalyticsStatus: Equatable, Sendable {
    case unknown
    case enabled
    case disabled

    static func parse(_ output: String) -> Self? {
        for line in output.split(whereSeparator: \.isNewline) {
            switch line.trimmingCharacters(in: .whitespaces).lowercased() {
            case "influxdb analytics are enabled.":
                return .enabled
            case "influxdb analytics are disabled.":
                return .disabled
            default:
                continue
            }
        }
        return nil
    }
}

extension BrewService {
    func refreshHomebrewAnalyticsStatus() async {
        guard !isUpdatingHomebrewAnalytics else { return }
        isUpdatingHomebrewAnalytics = true
        homebrewAnalyticsError = nil
        defer { isUpdatingHomebrewAnalytics = false }

        _ = await loadHomebrewAnalyticsStatus()
    }

    func setHomebrewAnalyticsEnabled(_ enabled: Bool) async {
        guard !isUpdatingHomebrewAnalytics else {
            homebrewAnalyticsError = "Wait for the current analytics operation to finish."
            return
        }
        isUpdatingHomebrewAnalytics = true
        homebrewAnalyticsError = nil
        defer { isUpdatingHomebrewAnalytics = false }

        let action = enabled ? "on" : "off"
        let result = await runBrewCommand(["analytics", action])
        guard !result.cancelled else { return }
        guard result.success else {
            homebrewAnalyticsError = BrewError.commandFailed(
                command: "analytics \(action)",
                output: result.output
            ).localizedDescription
            return
        }

        guard let reportedStatus = await loadHomebrewAnalyticsStatus() else { return }
        let expectedStatus: HomebrewAnalyticsStatus = enabled ? .enabled : .disabled
        if reportedStatus != expectedStatus {
            homebrewAnalyticsError = "Homebrew still reports analytics as \(reportedStatus.description). "
                + "Check your Homebrew environment and configuration."
        }
    }

    private func loadHomebrewAnalyticsStatus() async -> HomebrewAnalyticsStatus? {
        let result = await runBrewCommand(["analytics", "state"])
        guard !result.cancelled else { return nil }
        guard result.success else {
            homebrewAnalyticsError = BrewError.commandFailed(
                command: "analytics state",
                output: result.output
            ).localizedDescription
            return nil
        }
        guard let status = HomebrewAnalyticsStatus.parse(result.standardOutput) else {
            homebrewAnalyticsError = "Homebrew returned an unrecognized analytics status."
            return nil
        }

        homebrewAnalyticsStatus = status
        return status
    }
}

extension HomebrewAnalyticsStatus {
    fileprivate var description: String {
        switch self {
        case .unknown: "unknown"
        case .enabled: "enabled"
        case .disabled: "disabled"
        }
    }
}
