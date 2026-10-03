import XCTest

extension SidebarNavigationUITests {
    func testCaskDetailSeparatesAppAndRecordedVersions() {
        let casks = app.outlines.firstMatch.staticTexts["Casks"]
        assertExists(casks, timeout: Self.launchTimeout, "Casks category should appear")
        casks.click()
        let firefox = app.staticTexts["package-row-firefox"]
        assertExists(firefox, timeout: Self.elementTimeout, "Firefox should appear")
        firefox.click()

        let detail = app.scrollViews["package-detail-scroll"]
        assertExists(detail, timeout: Self.elementTimeout, "Cask details should appear")
        let appVersion = detail.descendants(matching: .any)["package-detail-app-version"]
        assertExists(appVersion, timeout: Self.elementTimeout, "App metadata should have its own field")
        XCTAssertEqual(appVersion.label, "App Version: 127.0.1")
        XCTAssertTrue(detail.staticTexts["Recorded version 127.0 → 128.0"].exists)
        XCTAssertTrue(detail.staticTexts["127.0"].exists)
        XCTAssertTrue(detail.staticTexts["128.0"].exists)
    }
}
