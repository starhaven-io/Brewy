@testable import Brewy
import Testing

@Suite("Homebrew Analytics Settings")
@MainActor
struct HomebrewAnalyticsTests {
    @Test("Parses enabled analytics state while ignoring legacy analytics output")
    func parsesEnabledState() {
        let output = """
        InfluxDB analytics are enabled.
        Google Analytics were destroyed.
        """

        #expect(HomebrewAnalyticsStatus.parse(output) == .enabled)
    }

    @Test("Parses disabled analytics state")
    func parsesDisabledState() {
        #expect(HomebrewAnalyticsStatus.parse("InfluxDB analytics are disabled.") == .disabled)
    }

    @Test("Rejects unrecognized analytics state")
    func rejectsUnrecognizedState() {
        #expect(HomebrewAnalyticsStatus.parse("Google Analytics were destroyed.") == nil)
    }

    @Test("Loads the current analytics state")
    func loadsCurrentState() async {
        let mock = MockCommandRunner()
        let (service, _) = makeService(mock: mock)
        mock.setResult(
            for: ["analytics", "state"],
            output: "InfluxDB analytics are enabled.\nGoogle Analytics were destroyed.\n"
        )

        await service.refreshHomebrewAnalyticsStatus()

        #expect(service.homebrewAnalyticsStatus == .enabled)
        #expect(service.homebrewAnalyticsError == nil)
        #expect(!service.isUpdatingHomebrewAnalytics)
        #expect(mock.executedCommands == [["analytics", "state"]])
    }

    @Test("Reports an unrecognized successful state response")
    func reportsUnrecognizedState() async {
        let mock = MockCommandRunner()
        let (service, _) = makeService(mock: mock)
        mock.setResult(for: ["analytics", "state"], output: "Google Analytics were destroyed.\n")

        await service.refreshHomebrewAnalyticsStatus()

        #expect(service.homebrewAnalyticsStatus == .unknown)
        #expect(service.homebrewAnalyticsError == "Homebrew returned an unrecognized analytics status.")
    }

    @Test("Cancellation does not surface an analytics error")
    func cancellationIsSilent() async {
        let mock = MockCommandRunner()
        let (service, _) = makeService(mock: mock)
        mock.setResult(
            for: ["analytics", "state"],
            result: CommandResult(output: "Command was cancelled.", success: false, cancelled: true)
        )

        await service.refreshHomebrewAnalyticsStatus()

        #expect(service.homebrewAnalyticsStatus == .unknown)
        #expect(service.homebrewAnalyticsError == nil)
        #expect(!service.isUpdatingHomebrewAnalytics)
    }

    @Test("Disables analytics and reloads the reported state")
    func disablesAnalytics() async {
        let mock = MockCommandRunner()
        let (service, _) = makeService(mock: mock)
        service.homebrewAnalyticsStatus = .enabled
        mock.setResult(for: ["analytics", "off"], output: "Homebrew analytics have been disabled.")
        mock.setResult(for: ["analytics", "state"], output: "InfluxDB analytics are disabled.")

        await service.setHomebrewAnalyticsEnabled(false)

        #expect(service.homebrewAnalyticsStatus == .disabled)
        #expect(service.homebrewAnalyticsError == nil)
        #expect(mock.executedCommands == [["analytics", "off"], ["analytics", "state"]])
    }

    @Test("Uses the reported state instead of assuming analytics were enabled")
    func reloadsStateAfterEnabling() async {
        let mock = MockCommandRunner()
        let (service, _) = makeService(mock: mock)
        service.homebrewAnalyticsStatus = .disabled
        mock.setResult(for: ["analytics", "on"], output: "Homebrew analytics have been enabled.")
        mock.setResult(for: ["analytics", "state"], output: "InfluxDB analytics are disabled.")

        await service.setHomebrewAnalyticsEnabled(true)

        #expect(service.homebrewAnalyticsStatus == .disabled)
        #expect(
            service.homebrewAnalyticsError
                == "Homebrew still reports analytics as disabled. Check your Homebrew environment and configuration."
        )
        #expect(mock.executedCommands == [["analytics", "on"], ["analytics", "state"]])
    }

    @Test("Enables analytics and reloads the reported state")
    func enablesAnalytics() async {
        let mock = MockCommandRunner()
        let (service, _) = makeService(mock: mock)
        service.homebrewAnalyticsStatus = .disabled
        mock.setResult(for: ["analytics", "on"], output: "Homebrew analytics have been enabled.")
        mock.setResult(for: ["analytics", "state"], output: "InfluxDB analytics are enabled.")

        await service.setHomebrewAnalyticsEnabled(true)

        #expect(service.homebrewAnalyticsStatus == .enabled)
        #expect(service.homebrewAnalyticsError == nil)
        #expect(mock.executedCommands == [["analytics", "on"], ["analytics", "state"]])
    }

    @Test("A failed follow-up query preserves the last known state")
    func preservesStateWhenReloadFails() async {
        let mock = MockCommandRunner()
        let (service, _) = makeService(mock: mock)
        service.homebrewAnalyticsStatus = .disabled
        mock.setResult(for: ["analytics", "on"], output: "Homebrew analytics have been enabled.")
        mock.setResult(
            for: ["analytics", "state"],
            result: CommandResult(output: "Error: unable to read configuration", success: false)
        )

        await service.setHomebrewAnalyticsEnabled(true)

        #expect(service.homebrewAnalyticsStatus == .disabled)
        #expect(service.homebrewAnalyticsError == "Error: unable to read configuration")
        #expect(mock.executedCommands == [["analytics", "on"], ["analytics", "state"]])
    }

    @Test("A cancelled setting change preserves the last known state")
    func preservesStateOnSettingCancellation() async {
        let mock = MockCommandRunner()
        let (service, _) = makeService(mock: mock)
        service.homebrewAnalyticsStatus = .enabled
        mock.setResult(
            for: ["analytics", "off"],
            result: CommandResult(output: "Command was cancelled.", success: false, cancelled: true)
        )

        await service.setHomebrewAnalyticsEnabled(false)

        #expect(service.homebrewAnalyticsStatus == .enabled)
        #expect(service.homebrewAnalyticsError == nil)
        #expect(mock.executedCommands == [["analytics", "off"]])
    }

    @Test("A concurrent setting request is rejected visibly")
    func reportsConcurrentSettingRequest() async {
        let mock = MockCommandRunner()
        let (service, _) = makeService(mock: mock)
        service.homebrewAnalyticsStatus = .enabled
        service.isUpdatingHomebrewAnalytics = true

        await service.setHomebrewAnalyticsEnabled(false)

        #expect(service.homebrewAnalyticsStatus == .enabled)
        #expect(service.isUpdatingHomebrewAnalytics)
        #expect(service.homebrewAnalyticsError == "Wait for the current analytics operation to finish.")
        #expect(mock.executedCommands.isEmpty)
    }

    @Test("A concurrent refresh does not clear another operation's state")
    func preservesConcurrentOperationDuringRefresh() async {
        let mock = MockCommandRunner()
        let (service, _) = makeService(mock: mock)
        service.homebrewAnalyticsStatus = .enabled
        service.isUpdatingHomebrewAnalytics = true

        await service.refreshHomebrewAnalyticsStatus()

        #expect(service.homebrewAnalyticsStatus == .enabled)
        #expect(service.isUpdatingHomebrewAnalytics)
        #expect(mock.executedCommands.isEmpty)
    }

    @Test("A completing refresh preserves a concurrent request warning")
    func preservesConcurrentRequestWarningAfterRefresh() async {
        let mock = MockCommandRunner()
        let (service, _) = makeService(mock: mock)
        service.homebrewAnalyticsStatus = .enabled
        mock.setResult(for: ["analytics", "state"], output: "InfluxDB analytics are enabled.")
        mock.setDelay(for: ["analytics", "state"], duration: .milliseconds(100))

        let refresh = Task { await service.refreshHomebrewAnalyticsStatus() }
        for _ in 0..<100 where mock.executedCommands.isEmpty {
            await Task.yield()
        }
        #expect(mock.executedCommands == [["analytics", "state"]])

        await service.setHomebrewAnalyticsEnabled(false)
        #expect(service.homebrewAnalyticsError == "Wait for the current analytics operation to finish.")
        await refresh.value

        #expect(service.homebrewAnalyticsStatus == .enabled)
        #expect(service.homebrewAnalyticsError == "Wait for the current analytics operation to finish.")
        #expect(!service.isUpdatingHomebrewAnalytics)
    }

    @Test("A failed setting change preserves the last known state")
    func preservesStateOnSettingFailure() async {
        let mock = MockCommandRunner()
        let (service, _) = makeService(mock: mock)
        service.homebrewAnalyticsStatus = .enabled
        mock.setResult(
            for: ["analytics", "off"],
            result: CommandResult(output: "Error: configuration is read-only", success: false)
        )

        await service.setHomebrewAnalyticsEnabled(false)

        #expect(service.homebrewAnalyticsStatus == .enabled)
        #expect(service.homebrewAnalyticsError == "Error: configuration is read-only")
        #expect(mock.executedCommands == [["analytics", "off"]])
    }
}
