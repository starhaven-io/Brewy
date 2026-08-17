import XCTest

@MainActor
final class DockIconSettingsUITests: XCTestCase {
    private static let timeoutScale: TimeInterval = isThreadSanitizerActive ? 4 : 1
    private static let launchTimeout: TimeInterval = 30 * timeoutScale
    private static let transitionTimeout: TimeInterval = 10 * timeoutScale

    private var app: XCUIApplication!
    private var fixtureDirectory: URL!

    override func setUp() async throws {
        continueAfterFailure = false
        fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("brewy-dock-icon-ui-tests-\(ProcessInfo.processInfo.globallyUniqueString)")
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)

        launch(showDockIcon: false)
    }

    override func tearDown() async throws {
        app?.terminate()
        app = nil
        try? FileManager.default.removeItem(at: fixtureDirectory)
        fixtureDirectory = nil
    }

    func testMenuBarOnlyLaunchCanOpenMainWindow() {
        XCTAssertFalse(
            app.windows.firstMatch.waitForExistence(timeout: 2 * Self.timeoutScale),
            "The main window should be suppressed when the Dock icon is hidden"
        )

        let statusItem = app.menuBars.statusItems["brewy-menu-bar-icon"]
        XCTAssertTrue(
            statusItem.waitForExistence(timeout: Self.launchTimeout),
            "The menu bar icon should remain available"
        )
        statusItem.click()

        XCTAssertTrue(
            app.menuItems["2 packages outdated"].waitForExistence(timeout: Self.transitionTimeout),
            "The menu bar should load package state without opening the main window"
        )

        let openBrewy = app.menuItems["Open Brewy"]
        XCTAssertTrue(
            openBrewy.waitForExistence(timeout: Self.transitionTimeout),
            "The menu bar should offer an Open Brewy action"
        )
        openBrewy.click()

        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: Self.transitionTimeout),
            "Open Brewy should activate the app"
        )
        let mainWindow = app.windows.firstMatch
        XCTAssertTrue(
            mainWindow.waitForExistence(timeout: Self.transitionTimeout),
            "Open Brewy should present the main window"
        )
        XCTAssertTrue(mainWindow.isHittable, "The opened main window should be in the foreground")
    }

    func testOpenBrewyActivatesExistingMainWindow() {
        launch(showDockIcon: true)

        let mainWindow = app.windows.firstMatch
        XCTAssertTrue(
            mainWindow.waitForExistence(timeout: Self.launchTimeout),
            "The main window should open at launch when the Dock icon is visible"
        )
        XCTAssertEqual(app.windows.count, 1, "The app should start with one main window")

        let statusItem = app.menuBars.statusItems["brewy-menu-bar-icon"]
        XCTAssertTrue(
            statusItem.waitForExistence(timeout: Self.launchTimeout),
            "The menu bar icon should remain available"
        )

        statusItem.click()
        let openBrewy = statusItem.menuItems["Open Brewy"]
        XCTAssertTrue(
            openBrewy.waitForExistence(timeout: Self.transitionTimeout),
            "The menu bar should offer an Open Brewy action"
        )
        openBrewy.click()
        XCTAssertFalse(
            app.windows.element(boundBy: 1).waitForExistence(timeout: 2 * Self.timeoutScale),
            "Open Brewy should not create another main window"
        )
        XCTAssertEqual(app.windows.count, 1, "Open Brewy should keep one main window")
        XCTAssertTrue(mainWindow.isHittable, "The main window should be in the foreground")
    }

    func testMenuBarOnlyLaunchCanOpenSettings() {
        XCTAssertFalse(
            app.windows.firstMatch.waitForExistence(timeout: 2 * Self.timeoutScale),
            "The main window should be suppressed when the Dock icon is hidden"
        )

        let statusItem = app.menuBars.statusItems["brewy-menu-bar-icon"]
        XCTAssertTrue(
            statusItem.waitForExistence(timeout: Self.launchTimeout),
            "The menu bar icon should remain available"
        )
        statusItem.click()

        let settings = statusItem.menuItems["Settings…"]
        XCTAssertTrue(
            settings.waitForExistence(timeout: Self.transitionTimeout),
            "The menu bar should offer a Settings action"
        )
        settings.click()

        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: Self.transitionTimeout),
            "Settings should activate the app"
        )
        let settingsWindow = app.windows["Brewy Settings"]
        XCTAssertTrue(
            settingsWindow.waitForExistence(timeout: Self.transitionTimeout),
            "Settings should present the Settings window"
        )
        XCTAssertTrue(settingsWindow.isHittable, "The Settings window should be in the foreground")
    }

    func testMenuBarShowsCountOnlyWhenUpdatesAreAvailable() {
        let statusItemWithUpdates = app.menuBars.statusItems["brewy-menu-bar-icon"]
        XCTAssertTrue(
            statusItemWithUpdates.waitForExistence(timeout: Self.launchTimeout),
            "The menu bar icon should remain available"
        )
        statusItemWithUpdates.click()
        XCTAssertTrue(
            app.menuItems["2 packages outdated"].waitForExistence(timeout: Self.transitionTimeout),
            "The fixture updates should load before measuring the menu bar item"
        )
        app.typeKey(.escape, modifierFlags: [])
        let widthWithUpdates = statusItemWithUpdates.frame.width

        app.terminate()
        app.launchEnvironment["BREWY_UI_NO_OUTDATED_PACKAGES"] = "1"
        app.launch()

        let statusItemWithoutUpdates = app.menuBars.statusItems["brewy-menu-bar-icon"]
        XCTAssertTrue(
            statusItemWithoutUpdates.waitForExistence(timeout: Self.launchTimeout),
            "The menu bar icon should remain available without updates"
        )
        XCTAssertGreaterThan(
            widthWithUpdates,
            statusItemWithoutUpdates.frame.width,
            "The update count should add visible text next to the menu bar icon"
        )
    }

    private func launch(showDockIcon: Bool) {
        app?.terminate()
        app = XCUIApplication()
        app.launchArguments += [
            "-ApplePersistenceIgnoreState", "YES",
            "-autoRefreshInterval", "0",
            "-brewfilePath", "",
            "-showCasksByDefault", "NO",
            "-showDockIcon", showDockIcon ? "YES" : "NO",
            "-showMenuBarIcon", "YES"
        ]
        app.launchEnvironment["BREWY_UI_TESTING"] = "1"
        app.launchEnvironment["XDG_CONFIG_HOME"] = fixtureDirectory.path
        app.launch()
    }

    private static var isThreadSanitizerActive: Bool {
        (0..<_dyld_image_count()).contains { index in
            guard let name = _dyld_get_image_name(index) else { return false }
            return String(cString: name).contains("libclang_rt.tsan")
        }
    }
}
