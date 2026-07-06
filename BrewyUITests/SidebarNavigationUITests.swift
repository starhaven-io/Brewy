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
    private static let launchTimeout: TimeInterval = 30 * timeoutScale
    private static let elementTimeout: TimeInterval = 10 * timeoutScale

    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-NSConstraintBasedLayoutVisualizeMutuallyExclusiveConstraints", "YES"]
        app.launchEnvironment["BREWY_UI_TESTING"] = "1"
        app.launch()
    }

    override func tearDown() async throws {
        app = nil
    }

    // MARK: - Sidebar Category Navigation

    func testAllSidebarCategoriesRender() throws {
        let categories = [
            "Installed", "Formulae", "Casks", "Mac App Store", "Outdated",
            "Pinned", "Leaves", "Taps", "Services", "Groups",
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
            "Pinned", "Leaves", "Taps", "Services", "Groups",
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

    // MARK: - Helpers

    /// Waits for `element` to exist via an explicit `XCTWaiter` expectation and
    /// asserts it appeared. Wrapping `waitForExistence` this way lets every wait
    /// share the TSan-scaled timeouts and keeps the assertion message intact.
    private func assertExists(
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
