import CryptoKit
import XCTest

@MainActor
final class SidebarNavigationUITests: XCTestCase {

    // Thread Sanitizer instrumentation slows the app under test enough that the
    // sidebar can take much longer than the unscaled timeouts to render, which
    // flaked these waits in CI's TSan job. Scale every timeout and settle delay
    // up when the sanitizer runtime is loaded: the UI-test bundle is built with
    // the same scheme setting as the app, so its presence in this process is a
    // reliable proxy for "the app under test is instrumented too".
    private static let timeoutScale: TimeInterval = isThreadSanitizerActive ? 4 : 1
    static let launchTimeout: TimeInterval = 30 * timeoutScale
    static let elementTimeout: TimeInterval = 10 * timeoutScale

    var app: XCUIApplication!
    private var fixtureDirectory: URL!

    override func setUp() async throws {
        continueAfterFailure = false
        fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("brewy-ui-tests-\(ProcessInfo.processInfo.globallyUniqueString)")
        let homebrewDirectory = fixtureDirectory.appendingPathComponent("homebrew")
        try FileManager.default.createDirectory(at: homebrewDirectory, withIntermediateDirectories: true)
        let brewfileURL = homebrewDirectory.appendingPathComponent("Brewfile")
            .resolvingSymlinksInPath()
        let brewfileData = Data("brew \"ripgrep\"\ncask \"firefox\"\n".utf8)
        try brewfileData.write(to: brewfileURL)
        let brewfileDigest = SHA256.hash(data: brewfileData)
            .map { String(format: "%02x", $0) }
            .joined()

        app = XCUIApplication()
        app.terminate()
        app.launchArguments += [
            "-NSConstraintBasedLayoutVisualizeMutuallyExclusiveConstraints", "YES",
            "-autoRefreshInterval", "0",
            "-brewfilePath", "",
            "-showCasksByDefault", "NO",
            "-showDockIcon", "YES",
            "-showMenuBarIcon", "YES",
            "-trustedBrewfilePath", brewfileURL.path,
            "-trustedBrewfileDigest", brewfileDigest
        ]
        app.launchEnvironment["BREWY_UI_TESTING"] = "1"
        app.launchEnvironment["XDG_CONFIG_HOME"] = fixtureDirectory.path
        app.launch()
        app.activate()
    }

    override func tearDown() async throws {
        app?.terminate()
        app = nil
        try? FileManager.default.removeItem(at: fixtureDirectory)
        fixtureDirectory = nil
    }

    // MARK: - Sidebar Category Navigation

    func testAllSidebarCategoriesRender() throws {
        let categories = [
            "Installed", "Formulae", "Casks", "Mac App Store", "Outdated",
            "Pinned", "Leaves", "Taps", "Services", "Groups", "Bundle",
            "History", "Discover", "Maintenance"
        ]

        let sidebar = app.outlines.firstMatch

        for (index, category) in categories.enumerated() {
            let row = sidebar.staticTexts[category]
            let timeout = index == 0 ? Self.launchTimeout : Self.elementTimeout
            assertExists(row, timeout: timeout, "Sidebar category '\(category)' should exist")
            row.click()
            settle()
        }
    }

    func testSidebarContainsAllCategories() throws {
        let sidebar = app.outlines.firstMatch
        assertExists(sidebar, timeout: Self.launchTimeout, "Sidebar should exist")

        let expectedCategories = [
            "Installed", "Formulae", "Casks", "Mac App Store", "Outdated",
            "Pinned", "Leaves", "Taps", "Services", "Groups", "Bundle",
            "History", "Discover", "Maintenance"
        ]

        for category in expectedCategories {
            assertExists(
                sidebar.staticTexts[category],
                timeout: Self.elementTimeout,
                "Sidebar should contain '\(category)' category"
            )
        }
    }

    // MARK: - Maintenance View (Regression: Layout Constraints)

    func testMaintenanceViewTransition() throws {
        let sidebar = app.outlines.firstMatch

        let installed = sidebar.staticTexts["Installed"]
        assertExists(installed, timeout: Self.launchTimeout, "Sidebar category 'Installed' should exist")
        installed.click()
        settle()

        let maintenance = sidebar.staticTexts["Maintenance"]
        assertExists(maintenance, timeout: Self.elementTimeout, "Sidebar category 'Maintenance' should exist")
        maintenance.click()
        settle()

        assertExists(
            installed,
            timeout: Self.elementTimeout,
            "Sidebar category 'Installed' should remain after returning from Maintenance"
        )
        installed.click()
        settle()
    }

    // MARK: - Refresh Button

    func testRefreshButtonExists() throws {
        let refreshButton = app.buttons["Refresh"]
        assertExists(
            refreshButton,
            timeout: Self.launchTimeout,
            "Refresh button should exist in sidebar footer"
        )
    }

    // MARK: - Fixture-backed flows

    func testPackageDetailRendersFixtureData() throws {
        let package = app.staticTexts["package-row-ripgrep"]
        assertExists(package, timeout: Self.launchTimeout, "Fixture package should appear")
        package.click()

        assertExists(
            app.staticTexts["Search tool like grep and The Silver Searcher"],
            timeout: Self.elementTimeout,
            "Package details should render"
        )
        assertExists(
            app.buttons["Upgrade"],
            timeout: Self.elementTimeout,
            "Outdated package should offer Upgrade"
        )
        assertExists(
            app.staticTexts["Version 14.1.0 → 14.1.1"],
            timeout: Self.elementTimeout,
            "Package version transition should render"
        )
    }

    func testManagementViewsRenderFixtureDetails() throws {
        let sidebar = app.outlines.firstMatch
        assertExists(sidebar, timeout: Self.launchTimeout, "Sidebar should exist")

        sidebar.staticTexts["Taps"].click()
        let tap = app.staticTexts["tap-row-starhaven-io/tap"]
        assertExists(tap, timeout: Self.elementTimeout, "Fixture tap should appear")
        tap.click()
        assertExists(
            app.staticTexts["https://github.com/starhaven-io/homebrew-tap"].firstMatch,
            timeout: Self.elementTimeout,
            "Tap details should render"
        )

        sidebar.staticTexts["Services"].click()
        let service = app.staticTexts["service-row-postgresql@17"]
        assertExists(service, timeout: Self.elementTimeout, "Fixture service should appear")
        service.click()
        assertExists(
            app.staticTexts["homebrew.mxcl.postgresql@17"],
            timeout: Self.elementTimeout,
            "Service details should render"
        )

        sidebar.staticTexts["Groups"].click()
        let group = app.staticTexts["group-row-Development"]
        assertExists(group, timeout: Self.elementTimeout, "Fixture group should appear")
        group.click()
        assertExists(
            app.staticTexts["2 packages"],
            timeout: Self.elementTimeout,
            "Group package count should render"
        )

        sidebar.staticTexts["Bundle"].click()
        assertExists(
            app.staticTexts["Missing Dependencies"],
            timeout: Self.elementTimeout,
            "Bundle status should render"
        )
        assertExists(
            app.staticTexts["jq"].firstMatch,
            timeout: Self.elementTimeout,
            "Missing bundle entry should render"
        )
    }

    func testHistoryDiscoverAndMaintenanceRenderFixtureData() throws {
        let sidebar = app.outlines.firstMatch
        assertExists(sidebar, timeout: Self.launchTimeout, "Sidebar should exist")

        sidebar.staticTexts["History"].click()
        let historyEntry = app.staticTexts["history-row-ripgrep"]
        assertExists(historyEntry, timeout: Self.elementTimeout, "Fixture history should appear")
        historyEntry.click()
        assertExists(
            app.staticTexts["brew upgrade ripgrep"],
            timeout: Self.elementTimeout,
            "History command should render"
        )
        assertExists(
            app.staticTexts["Error: fixture upgrade failed"],
            timeout: Self.elementTimeout,
            "History output should render"
        )

        sidebar.staticTexts["Discover"].click()
        assertExists(
            app.staticTexts["atuin"].firstMatch,
            timeout: Self.elementTimeout,
            "New formula should appear in Discover"
        )
        assertExists(
            app.staticTexts["zed"].firstMatch,
            timeout: Self.elementTimeout,
            "New cask should appear in Discover"
        )

        sidebar.staticTexts["Maintenance"].click()
        assertExists(
            app.staticTexts["4.6.0"],
            timeout: Self.elementTimeout,
            "Fixture Homebrew version should render"
        )
        assertExists(
            app.staticTexts["maintenance-cache-size"],
            timeout: Self.elementTimeout,
            "Fixture cache size should render"
        )
    }

    // MARK: - Helpers

    /// Waits for `element` to exist via an explicit `XCTWaiter` expectation and
    /// asserts it appeared. Wrapping `waitForExistence` this way lets every wait
    /// share the TSan-scaled timeouts and keeps the assertion message intact.
    func assertExists(
        _ element: XCUIElement,
        timeout: TimeInterval,
        _ message: @autoclosure () -> String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true"),
            object: element
        )
        let outcome = XCTWaiter().wait(for: [expectation], timeout: timeout)
        XCTAssertEqual(outcome, .completed, message(), file: file, line: line)
    }

    /// Lets navigation animations and layout settle between interactions. The
    /// delay is scaled so TSan builds get proportionally more time.
    private func settle(_ seconds: TimeInterval = 0.5) {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds * Self.timeoutScale))
    }

    /// True when the Thread Sanitizer runtime is loaded into this process.
    private static var isThreadSanitizerActive: Bool {
        (0..<_dyld_image_count()).contains { index in
            guard let name = _dyld_get_image_name(index) else { return false }
            return String(cString: name).contains("libclang_rt.tsan")
        }
    }
}

@MainActor
final class MenuBarSettingsUITests: XCTestCase {
    private static let timeoutScale: TimeInterval = isThreadSanitizerActive ? 4 : 1
    private static let launchTimeout: TimeInterval = 30 * timeoutScale
    private static let transitionTimeout: TimeInterval = 10 * timeoutScale

    private var app: XCUIApplication!
    private var fixtureDirectory: URL!
    private var initialMenuBarIconState: Bool?

    override func setUp() async throws {
        continueAfterFailure = false
        fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("brewy-menu-bar-ui-tests-\(ProcessInfo.processInfo.globallyUniqueString)")
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)

        app = XCUIApplication()
        app.terminate()
        // This class intentionally omits showMenuBarIcon so the toggle can write through AppStorage.
        app.launchArguments += [
            "-NSConstraintBasedLayoutVisualizeMutuallyExclusiveConstraints", "YES",
            "-autoRefreshInterval", "0",
            "-brewfilePath", "",
            "-showCasksByDefault", "NO",
            "-showDockIcon", "YES"
        ]
        app.launchEnvironment["BREWY_UI_TESTING"] = "1"
        app.launchEnvironment["XDG_CONFIG_HOME"] = fixtureDirectory.path
        app.launch()
        app.activate()
    }

    override func tearDown() async throws {
        restoreInitialMenuBarIconStateIfNeeded()
        app?.terminate()
        app = nil
        try? FileManager.default.removeItem(at: fixtureDirectory)
        fixtureDirectory = nil
    }

    func testMenuBarIconVisibilityPersistsAcrossRelaunch() throws {
        let toggle = try openMenuBarIconSetting()
        let initialState = try XCTUnwrap(checkedValue(of: toggle))
        initialMenuBarIconState = initialState

        XCTAssertTrue(waitForMenuBarCount(initialState ? 2 : 1))

        let toggledState = !initialState
        toggle.click()
        XCTAssertTrue(waitUntil { self.checkedValue(of: toggle) == toggledState })
        XCTAssertTrue(waitForMenuBarCount(toggledState ? 2 : 1))

        app.terminate()
        app.launch()
        app.activate()

        let relaunchedToggle = try openMenuBarIconSetting()
        XCTAssertEqual(checkedValue(of: relaunchedToggle), toggledState)
        XCTAssertTrue(waitForMenuBarCount(toggledState ? 2 : 1))

        relaunchedToggle.click()
        XCTAssertTrue(waitUntil { self.checkedValue(of: relaunchedToggle) == initialState })
        XCTAssertTrue(waitForMenuBarCount(initialState ? 2 : 1))
        initialMenuBarIconState = nil
    }

    private func openMenuBarIconSetting() throws -> XCUIElement {
        app.typeKey(",", modifierFlags: .command)

        let settingsWindow = app.windows["Brewy Settings"]
        _ = try XCTUnwrap(
            settingsWindow.waitForExistence(timeout: Self.launchTimeout) ? settingsWindow : nil,
            "Settings window should appear"
        )

        let toggle = settingsWindow.switches["show-menu-bar-icon-toggle"]
        return try XCTUnwrap(
            toggle.waitForExistence(timeout: Self.transitionTimeout) ? toggle : nil,
            "Menu bar icon setting should appear"
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

    private func waitForMenuBarCount(_ count: Int) -> Bool {
        waitUntil { self.app.menuBars.count == count }
    }

    private func waitUntil(_ condition: () -> Bool) -> Bool {
        let deadline = Date(timeIntervalSinceNow: Self.transitionTimeout)
        repeat {
            if condition() { return true }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        } while Date() < deadline
        return condition()
    }

    private func restoreInitialMenuBarIconStateIfNeeded() {
        guard let initialMenuBarIconState else { return }

        if app.state == .notRunning {
            app.launch()
        }
        app.activate()
        app.typeKey(",", modifierFlags: .command)

        let toggle = app.windows["Brewy Settings"].switches["show-menu-bar-icon-toggle"]
        guard toggle.waitForExistence(timeout: Self.launchTimeout),
              let currentState = checkedValue(of: toggle),
              currentState != initialMenuBarIconState else {
            return
        }

        toggle.click()
        _ = waitUntil { self.checkedValue(of: toggle) == initialMenuBarIconState }
    }

    private static var isThreadSanitizerActive: Bool {
        (0..<_dyld_image_count()).contains { index in
            guard let name = _dyld_get_image_name(index) else { return false }
            return String(cString: name).contains("libclang_rt.tsan")
        }
    }
}
