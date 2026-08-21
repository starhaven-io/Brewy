import XCTest

@MainActor
final class HomebrewAnalyticsUITests: XCTestCase {
    private static let launchTimeout: TimeInterval = 30
    private static let transitionTimeout: TimeInterval = 10

    private var app: XCUIApplication!
    private var fixtureDirectory: URL!

    override func setUp() async throws {
        continueAfterFailure = false
        fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("brewy-analytics-ui-tests-\(ProcessInfo.processInfo.globallyUniqueString)")
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        app?.terminate()
        app = nil
        try? FileManager.default.removeItem(at: fixtureDirectory)
        fixtureDirectory = nil
    }

    func testSettingTogglesReportedState() {
        launch()
        XCTAssertTrue(
            app.windows.firstMatch.waitForExistence(timeout: Self.launchTimeout),
            "The main window should open before presenting Settings"
        )
        app.typeKey(",", modifierFlags: .command)

        let settingsWindow = app.windows["Brewy Settings"]
        XCTAssertTrue(
            settingsWindow.waitForExistence(timeout: Self.transitionTimeout),
            "The Settings window should open from its keyboard shortcut"
        )

        let analyticsToggle = settingsWindow.switches["homebrew-analytics-toggle"]
        XCTAssertTrue(
            analyticsToggle.waitForExistence(timeout: Self.transitionTimeout),
            "Settings should expose Homebrew's analytics control"
        )
        let analyticsStatus = settingsWindow.descendants(matching: .any)["homebrew-analytics-status"]
        XCTAssertTrue(
            analyticsStatus.waitForExistence(timeout: Self.transitionTimeout),
            "Settings should report Homebrew's current analytics state"
        )
        assertLabel("Homebrew analytics status: Enabled", for: analyticsStatus)

        let editableToggle = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"),
            object: analyticsToggle
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [editableToggle], timeout: Self.transitionTimeout),
            .completed,
            "The loaded analytics setting should be editable"
        )
        assertCheckedValue(true, for: analyticsToggle)

        analyticsToggle.click()

        assertCheckedValue(false, for: analyticsToggle)
        assertLabel("Homebrew analytics status: Disabled", for: analyticsStatus)
    }

    func testUnavailableStateDoesNotRenderAsDisabledAndCanRetry() {
        launch(analyticsStateFailsOnce: true)
        XCTAssertTrue(
            app.windows.firstMatch.waitForExistence(timeout: Self.launchTimeout),
            "The main window should open before presenting Settings"
        )
        app.typeKey(",", modifierFlags: .command)

        let settingsWindow = app.windows["Brewy Settings"]
        XCTAssertTrue(
            settingsWindow.waitForExistence(timeout: Self.transitionTimeout),
            "The Settings window should open from its keyboard shortcut"
        )
        let analyticsStatus = settingsWindow.descendants(matching: .any)["homebrew-analytics-status"]
        XCTAssertTrue(
            analyticsStatus.waitForExistence(timeout: Self.transitionTimeout),
            "Settings should expose the analytics status"
        )
        assertLabel("Homebrew analytics status: Unavailable", for: analyticsStatus)
        XCTAssertFalse(
            settingsWindow.switches["homebrew-analytics-toggle"].exists,
            "An unknown analytics state must not render as an off switch"
        )

        let analyticsError = settingsWindow.descendants(matching: .any)["homebrew-analytics-error"]
        XCTAssertTrue(
            analyticsError.waitForExistence(timeout: Self.transitionTimeout),
            "Settings should explain why the analytics state is unavailable"
        )
        let retry = settingsWindow.buttons["homebrew-analytics-retry"]
        XCTAssertTrue(
            retry.waitForExistence(timeout: Self.transitionTimeout),
            "Settings should allow a failed analytics query to be retried"
        )
        retry.click()

        XCTAssertTrue(
            settingsWindow.switches["homebrew-analytics-toggle"].waitForExistence(
                timeout: Self.transitionTimeout
            ),
            "A successful retry should reveal the analytics toggle"
        )
        assertLabel("Homebrew analytics status: Enabled", for: analyticsStatus)
    }

    private func launch(analyticsStateFailsOnce: Bool = false) {
        app = XCUIApplication()
        app.launchArguments += [
            "-ApplePersistenceIgnoreState", "YES",
            "-autoRefreshInterval", "0",
            "-brewfilePath", "",
            "-showCasksByDefault", "NO",
            "-showDockIcon", "YES",
            "-showMenuBarIcon", "YES"
        ]
        app.launchEnvironment["BREWY_UI_TESTING"] = "1"
        app.launchEnvironment["XDG_CONFIG_HOME"] = fixtureDirectory.path
        if analyticsStateFailsOnce {
            app.launchEnvironment["BREWY_UI_ANALYTICS_STATE_FAILS_ONCE"] = "1"
        }
        app.launch()
        app.activate()
    }

    private func assertLabel(_ label: String, for element: XCUIElement) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@ OR value == %@", label, label),
            object: element
        )
        let result = XCTWaiter.wait(for: [expectation], timeout: Self.transitionTimeout)
        XCTAssertEqual(
            result,
            .completed,
            "Expected accessibility label or value '\(label)'; got label '\(element.label)' "
                + "and value '\(String(describing: element.value))'"
        )
    }

    private func assertCheckedValue(_ expectedValue: Bool, for toggle: XCUIElement) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { [self] object, _ in
                guard let toggle = object as? XCUIElement else { return false }
                return checkedValue(of: toggle) == expectedValue
            },
            object: toggle
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: Self.transitionTimeout),
            .completed,
            "Expected toggle value '\(expectedValue)'"
        )
    }

    private func checkedValue(of toggle: XCUIElement) -> Bool? {
        if let number = toggle.value as? NSNumber {
            return number.boolValue
        }

        guard let string = toggle.value as? String else { return nil }
        switch string.lowercased() {
        case "1", "true", "on": return true
        case "0", "false", "off": return false
        default: return nil
        }
    }
}
