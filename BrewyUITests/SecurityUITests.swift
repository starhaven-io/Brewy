import XCTest

@MainActor
final class SecurityUITests: XCTestCase {
    private static let timeoutScale: TimeInterval = isThreadSanitizerActive ? 4 : 1
    private static let launchTimeout: TimeInterval = 30 * timeoutScale
    private static let elementTimeout: TimeInterval = 10 * timeoutScale
    private static let securityScopeDescription =
        "Casks, Mac App Store apps, and apps installed outside Homebrew are not assessed."

    private var app: XCUIApplication!
    private var fixtureDirectory: URL!

    override func setUp() async throws {
        continueAfterFailure = false
        fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("brewy-security-ui-tests-\(ProcessInfo.processInfo.globallyUniqueString)")
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)

        app = XCUIApplication()
        app.terminate()
        app.launchArguments += [
            "-ApplePersistenceIgnoreState", "YES",
            "-NSConstraintBasedLayoutVisualizeMutuallyExclusiveConstraints", "YES",
            "-autoRefreshInterval", "0",
            "-brewfilePath", "",
            "-showCasksByDefault", "NO",
            "-showDockIcon", "YES",
            "-showMenuBarIcon", "YES"
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

    func testScanRequiresExplicitRequest() throws {
        openSecurity()

        let pane = app.descendants(matching: .any)["security-pane"]
        let scanButton = app.buttons["security-scan-button"]
        assertExists(pane, timeout: Self.elementTimeout, "Security pane should appear")
        assertExists(app.staticTexts["No Scan Yet"], timeout: Self.elementTimeout, "Initial state should appear")
        assertExists(scanButton, timeout: Self.elementTimeout, "Security scan button should appear")
        XCTAssertEqual(scanButton.label, "Run Scan")
        assertDoesNotExist(
            app.descendants(matching: .any)[
                "security-vulnerability-open|ripgrep|14.1.1|CVE-2026-1234"
            ],
            timeout: 1 * Self.timeoutScale,
            "No findings should appear before the user requests a scan"
        )
    }

    func testScanRendersOpenAndPatchedFindings() throws {
        openSecurity()

        let scanButton = app.buttons["security-scan-button"]
        assertExists(scanButton, timeout: Self.elementTimeout, "Security scan button should appear")
        XCTAssertEqual(scanButton.label, "Run Scan")
        scanButton.click()
        assertLabel(scanButton, equals: "Scan Again", "Security scan should complete")

        let openFinding = app.descendants(matching: .any)[
            "security-vulnerability-open|ripgrep|14.1.1|CVE-2026-1234"
        ]
        assertExists(openFinding, timeout: Self.elementTimeout, "An explicit scan should render the open finding")
        assertExists(
            app.staticTexts["Installed version: 14.1.0"],
            timeout: Self.elementTimeout,
            "The installed version should be labeled"
        )
        assertExists(
            app.staticTexts["Scanned target: 14.1.1"],
            timeout: Self.elementTimeout,
            "The queried release tag should be labeled"
        )
        assertExists(
            app.staticTexts["Homebrew Notice"],
            timeout: Self.elementTimeout,
            "Homebrew's warning should use a neutral heading"
        )

        let pane = app.descendants(matching: .any)["security-pane"]
        assertExists(pane, timeout: Self.elementTimeout, "Security results pane should appear")
        let scrollContainer = securityResultsScrollContainer(in: pane)
        assertExists(scrollContainer, timeout: Self.elementTimeout, "Security results should be scrollable")
        let initialOpenFindingY = openFinding.frame.midY
        scrollContainer.scroll(byDeltaX: 0, deltaY: -600)
        settle()
        XCTAssertLessThan(openFinding.frame.midY, initialOpenFindingY, "The results content should actually scroll")

        let patchedFinding = app.descendants(matching: .any)[
            "security-vulnerability-patched|ripgrep|14.1.1|CVE-2025-4321"
        ]
        assertExists(patchedFinding, timeout: Self.elementTimeout, "Formula-patched vulnerability should render")
        XCTAssertTrue(
            scrollContainer.frame.intersects(patchedFinding.frame),
            "The patched finding should be visible after scrolling the results container"
        )
    }

    func testFailureStateIsCenteredAndOffersRetry() throws {
        app.terminate()
        app.launchEnvironment["BREWY_UI_VULNERABILITY_SCAN_FAILURE"] = "1"
        app.launch()
        app.activate()
        openSecurity()

        let pane = app.descendants(matching: .any)["security-pane"]
        let scanButton = app.buttons["security-scan-button"]
        let failureTitle = app.staticTexts["Scan Failed"]
        assertExists(pane, timeout: Self.elementTimeout, "Security pane should appear")
        assertExists(scanButton, timeout: Self.elementTimeout, "Security scan button should appear")
        XCTAssertEqual(scanButton.label, "Run Scan")
        scanButton.click()
        assertLabel(scanButton, equals: "Retry Scan", "Failed scan should offer a retry")
        assertExists(failureTitle, timeout: Self.elementTimeout, "Failure state should appear")
        XCTAssertEqual(failureTitle.frame.midX, pane.frame.midX, accuracy: 30)
        XCTAssertEqual(failureTitle.frame.midY, pane.frame.midY, accuracy: 80)
        assertExists(
            app.staticTexts[Self.securityScopeDescription],
            timeout: Self.elementTimeout,
            "Failure state should retain the formula-only coverage disclaimer"
        )
        assertExists(
            app.buttons["Retry Vulnerability Scan"],
            timeout: Self.elementTimeout,
            "Failure state should offer an explicit retry action"
        )
    }

    private func openSecurity() {
        let sidebar = app.outlines.firstMatch
        assertExists(sidebar, timeout: Self.launchTimeout, "Sidebar should exist")
        sidebar.staticTexts["Security"].click()
    }

    private func assertExists(
        _ element: XCUIElement,
        timeout: TimeInterval,
        _ message: @autoclosure () -> String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), message(), file: file, line: line)
    }

    private func assertDoesNotExist(
        _ element: XCUIElement,
        timeout: TimeInterval,
        _ message: @autoclosure () -> String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(element.waitForExistence(timeout: timeout), message(), file: file, line: line)
    }

    private func assertLabel(
        _ element: XCUIElement,
        equals label: String,
        _ message: @autoclosure () -> String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", label),
            object: element
        )
        let outcome = XCTWaiter().wait(for: [expectation], timeout: Self.elementTimeout)
        XCTAssertEqual(outcome, .completed, message(), file: file, line: line)
    }

    private func securityResultsScrollContainer(in pane: XCUIElement) -> XCUIElement {
        if pane.elementType == .outline || pane.elementType == .scrollView {
            return pane
        }

        let outline = pane.outlines.firstMatch
        if outline.exists {
            return outline
        }
        return pane.scrollViews.firstMatch
    }

    private func settle(_ seconds: TimeInterval = 0.5) {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds * Self.timeoutScale))
    }

    private static var isThreadSanitizerActive: Bool {
        (0..<_dyld_image_count()).contains { index in
            guard let name = _dyld_get_image_name(index) else { return false }
            return String(cString: name).contains("libclang_rt.tsan")
        }
    }
}
