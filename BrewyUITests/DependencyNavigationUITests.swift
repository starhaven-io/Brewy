import XCTest

extension SidebarNavigationUITests {
    func testDependencyTreeRendersFixtureData() throws {
        let package = app.staticTexts["package-row-ripgrep"]
        assertExists(package, timeout: Self.launchTimeout, "Fixture package should appear")
        package.click()

        let detailScroll = app.scrollViews["package-detail-scroll"]
        assertExists(detailScroll, timeout: Self.elementTimeout, "Package detail should appear")
        detailScroll.scroll(byDeltaX: 0, deltaY: -500)

        let disclosure = app.disclosureTriangles["dependency-tree-forward-disclosure"]
        assertExists(disclosure, timeout: Self.elementTimeout, "Forward dependency tree should appear")
        XCTAssertEqual(disclosure.label, "Pulls in, 1", "Fixture dependency count should render")
    }

    func testExpandedDependencyTreesRenderRowsAndNavigate() throws {
        let package = app.staticTexts["package-row-ripgrep"]
        assertExists(package, timeout: Self.launchTimeout, "Fixture package should appear")
        package.click()

        let detailScroll = app.scrollViews["package-detail-scroll"]
        assertExists(detailScroll, timeout: Self.elementTimeout, "Package detail should appear")
        detailScroll.scroll(byDeltaX: 0, deltaY: -500)

        let forwardDisclosure = app.disclosureTriangles["dependency-tree-forward-disclosure"]
        assertExists(forwardDisclosure, timeout: Self.elementTimeout, "Forward dependency tree should appear")
        clickDisclosureTriangle(forwardDisclosure)
        XCTAssertEqual(
            (forwardDisclosure.value as? NSNumber)?.intValue,
            1,
            "Forward dependency tree should expand"
        )

        let dependency = app.buttons["pcre2"].firstMatch
        assertExists(dependency, timeout: Self.elementTimeout, "Expanded forward tree should show pcre2")
        XCTAssertLessThanOrEqual(
            dependency.frame.width,
            80,
            "Expanded dependency buttons should keep their intrinsic width"
        )
        XCTAssertLessThan(
            dependency.frame.midX,
            detailScroll.frame.midX - 40,
            "Expanded dependency rows should align with the leading edge"
        )
        dependency.click()

        let updatedDetailScroll = app.scrollViews["package-detail-scroll"]
        assertExists(updatedDetailScroll, timeout: Self.elementTimeout, "Navigated package detail should appear")
        updatedDetailScroll.scroll(byDeltaX: 0, deltaY: -500)

        let reverseDisclosure = app.disclosureTriangles["dependency-tree-reverse-disclosure"]
        assertExists(reverseDisclosure, timeout: Self.elementTimeout, "Reverse dependency tree should appear")
        XCTAssertEqual(reverseDisclosure.label, "Pulled in by, 1", "Reverse dependency count should render")
        clickDisclosureTriangle(reverseDisclosure)
        XCTAssertEqual(
            (reverseDisclosure.value as? NSNumber)?.intValue,
            1,
            "Reverse dependency tree should expand"
        )
        updatedDetailScroll.scroll(byDeltaX: 0, deltaY: -200)
        let dependent = app.buttons.matching(NSPredicate(format: "label == %@", "ripgrep")).firstMatch
        assertExists(
            dependent,
            timeout: Self.elementTimeout,
            "Expanded reverse tree should show ripgrep"
        )
        XCTAssertLessThan(
            dependent.frame.midX,
            updatedDetailScroll.frame.midX - 40,
            "Expanded reverse-dependency rows should align with the leading edge"
        )
    }

    func testCleanupPreviewEnablesConfirmationAfterSuccessfulDryRun() throws {
        openCleanupPreview()

        assertExists(
            app.staticTexts["Fixture cleanup preview"],
            timeout: Self.elementTimeout,
            "Successful dry-run output should appear"
        )
        let confirm = app.buttons["Clear Cache"]
        assertExists(confirm, timeout: Self.elementTimeout, "Clear Cache confirmation should appear")
        XCTAssertTrue(confirm.isEnabled, "A successful preview should enable confirmation")
        confirm.click()

        XCTAssertTrue(
            app.staticTexts["Clear Download Cache?"].waitForNonExistence(timeout: Self.elementTimeout),
            "Confirming should dismiss the preview"
        )
    }

    func testCleanupPreviewFailureKeepsConfirmationDisabled() throws {
        app.terminate()
        app.launchEnvironment["BREWY_UI_CLEANUP_PREVIEW_FAILURE"] = "1"
        app.launch()
        app.activate()

        openCleanupPreview()

        assertExists(app.staticTexts["Preview failed"], timeout: Self.elementTimeout, "Failure state should appear")
        assertExists(
            app.staticTexts["Fixture cleanup preview failed"],
            timeout: Self.elementTimeout,
            "Dry-run failure output should appear"
        )
        let confirm = app.buttons["Clear Cache"]
        assertExists(confirm, timeout: Self.elementTimeout, "Clear Cache confirmation should appear")
        XCTAssertFalse(confirm.isEnabled, "A failed preview must keep confirmation disabled")
    }

    private func openCleanupPreview() {
        let fileMenu = app.menuBars.menuBarItems["File"]
        assertExists(fileMenu, timeout: Self.launchTimeout, "File menu should exist")
        fileMenu.click()

        let cleanup = app.menuItems["Cleanup..."]
        assertExists(cleanup, timeout: Self.elementTimeout, "Cleanup command should exist")
        cleanup.click()

        assertExists(
            app.staticTexts["Clear Download Cache?"],
            timeout: Self.elementTimeout,
            "Cleanup preview should appear"
        )
    }

    private func clickDisclosureTriangle(_ disclosure: XCUIElement) {
        // SwiftUI includes leading padding and the label in this frame, so target the glyph at a fixed offset.
        let leadingEdge = disclosure.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
        leadingEdge.withOffset(CGVector(dx: 26, dy: 0)).click()
    }
}
