import XCTest

extension SidebarNavigationUITests {
    func testUpgradeSelectionSurvivesSearchHidingAllRows() {
        let outdated = app.outlines.firstMatch.staticTexts["Outdated"]
        assertExists(outdated, timeout: Self.launchTimeout, "Outdated category should appear")
        outdated.click()
        let select = app.buttons["Select"]
        assertExists(select, timeout: Self.elementTimeout, "Select should appear")
        select.click()

        let formula = app.checkBoxes["upgrade-selection-formula-ripgrep"]
        let cask = app.checkBoxes["upgrade-selection-cask-firefox"]
        assertExists(formula, timeout: Self.elementTimeout, "Formula checkbox should appear")
        assertExists(cask, timeout: Self.elementTimeout, "Cask checkbox should appear")
        formula.click()
        cask.click()

        let upgrade = app.buttons["Upgrade (2)"]
        assertExists(upgrade, timeout: Self.elementTimeout, "Both selections should be counted")
        let search = app.searchFields["package-search-field"].firstMatch
        search.click()
        search.typeText("ripgrep")
        XCTAssertTrue(cask.waitForNonExistence(timeout: Self.elementTimeout))
        XCTAssertTrue(upgrade.exists, "Hiding one selection must retain both upgrade targets")

        search.typeKey("a", modifierFlags: .command)
        search.typeText("no-matching-package")
        XCTAssertTrue(formula.waitForNonExistence(timeout: Self.elementTimeout))
        XCTAssertTrue(upgrade.exists, "Hiding every row must retain the selected-upgrade action")
        XCTAssertTrue(upgrade.isEnabled)
        XCTAssertTrue(app.buttons["Cancel"].exists)

        search.typeKey("a", modifierFlags: .command)
        search.typeKey(XCUIKeyboardKey.delete, modifierFlags: [])
        assertExists(formula, timeout: Self.elementTimeout, "Formula should reappear after clearing search")
        assertExists(cask, timeout: Self.elementTimeout, "Cask should reappear after clearing search")
        XCTAssertTrue((formula.value as? NSNumber)?.boolValue == true || (formula.value as? String) == "1")
        XCTAssertTrue((cask.value as? NSNumber)?.boolValue == true || (cask.value as? String) == "1")
        app.buttons["Cancel"].click()
        assertExists(select, timeout: Self.elementTimeout, "Cancel should leave selection mode")
    }
}
