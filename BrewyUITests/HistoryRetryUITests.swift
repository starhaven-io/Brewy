import XCTest

extension SidebarNavigationUITests {
    func testMaintenanceRetriesShowCurrentPreviewAndCanBeCanceled() {
        for command in ["cleanup", "autoremove"] {
            openMaintenanceRetry(command)
            let sheet = app.sheets.firstMatch
            assertExists(
                sheet.staticTexts["Fixture \(command) preview"], timeout: Self.elementTimeout,
                "Retry should display a fresh maintenance preview"
            )
            XCTAssertTrue(sheet.buttons["Retry"].isEnabled)
            sheet.buttons["Cancel"].click()
            XCTAssertTrue(sheet.waitForNonExistence(timeout: Self.elementTimeout))
            XCTAssertEqual(app.staticTexts.matching(identifier: "history-row-\(command)").count, 1)
        }
    }

    func testFailedMaintenanceRetryPreviewCannotBeConfirmed() {
        app.terminate()
        app.launchEnvironment["BREWY_UI_CLEANUP_PREVIEW_FAILURE"] = "1"
        app.launch()
        app.activate()

        openMaintenanceRetry("cleanup")
        let sheet = app.sheets.firstMatch
        assertExists(sheet.staticTexts["Preview failed"], timeout: Self.elementTimeout, "Preview must fail visibly")
        XCTAssertFalse(sheet.buttons["Retry"].isEnabled, "Failure must leave destructive retry disabled")
        sheet.buttons["Cancel"].click()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: Self.elementTimeout))
        XCTAssertEqual(app.staticTexts.matching(identifier: "history-row-cleanup").count, 1)
    }

    private func openMaintenanceRetry(_ command: String) {
        let history = app.outlines.firstMatch.staticTexts["History"]
        assertExists(history, timeout: Self.launchTimeout, "History should be available")
        history.click()
        let row = app.staticTexts["history-row-\(command)"].firstMatch
        assertExists(row, timeout: Self.elementTimeout, "Failed maintenance command should appear")
        row.click()
        let retry = app.buttons["Retry"]
        assertExists(retry, timeout: Self.elementTimeout, "Failed command should offer Retry")
        retry.click()
        assertExists(app.sheets.firstMatch, timeout: Self.elementTimeout, "Retry should open a dry-run sheet")
    }
}
