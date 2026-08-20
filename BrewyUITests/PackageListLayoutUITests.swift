import XCTest

extension SidebarNavigationUITests {
    func testPackageSearchSupportsFindAndEscape() throws {
        let searchField = packageSearchField()
        assertExists(searchField, timeout: Self.launchTimeout, "Package search should appear")
        let package = app.staticTexts["package-row-ripgrep"]
        assertExists(package, timeout: Self.elementTimeout, "Fixture package should appear")
        package.click()

        app.typeKey("f", modifierFlags: .command)
        app.typeText("wget")
        assertSearchField(searchField, hasValue: "wget")

        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        assertSearchField(searchField, hasValue: "")
    }

    func testClearingAllPackagesSearchRestoresInstalledList() throws {
        let scope = app.descendants(matching: .any)["package-search-scope"].firstMatch
        assertExists(scope, timeout: Self.launchTimeout, "Package search scope should appear")
        scope.click()
        let allPackages = app.menuItems["All Packages"]
        assertExists(allPackages, timeout: Self.elementTimeout, "All Packages scope should appear")
        allPackages.click()

        let searchField = packageSearchField()
        searchField.click()
        searchField.typeText("wget")
        searchField.typeKey("a", modifierFlags: .command)
        searchField.typeKey(XCUIKeyboardKey.delete, modifierFlags: [])
        assertSearchField(searchField, hasValue: "")

        assertExists(
            app.staticTexts["package-row-ripgrep"],
            timeout: Self.elementTimeout,
            "Clearing an all-package search should restore the selected category"
        )
    }

    func testUpgradeSelectionCancelUsesEscape() throws {
        let sidebar = app.outlines.firstMatch
        assertExists(sidebar, timeout: Self.launchTimeout, "Sidebar should appear")
        sidebar.staticTexts["Outdated"].click()

        let searchField = packageSearchField()
        assertExists(searchField, timeout: Self.elementTimeout, "Package search should appear")
        searchField.click()
        searchField.typeText("rip")

        let select = app.buttons["Select"]
        assertExists(select, timeout: Self.elementTimeout, "Select should appear")
        select.click()

        let cancel = app.buttons["Cancel"]
        assertExists(cancel, timeout: Self.elementTimeout, "Cancel should appear")
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        assertSearchField(searchField, hasValue: "")
        XCTAssertTrue(cancel.exists, "Clearing search should keep upgrade selection active")

        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])

        XCTAssertTrue(
            cancel.waitForNonExistence(timeout: Self.elementTimeout),
            "Escape should cancel upgrade selection"
        )
        assertExists(select, timeout: Self.elementTimeout, "Select should reappear after cancelling")
    }

    func testDiscoverSearchRemainsInsideContentColumn() throws {
        let sidebar = app.outlines.firstMatch
        assertExists(sidebar, timeout: Self.launchTimeout, "Sidebar should appear")
        sidebar.staticTexts["Discover"].click()

        let packageList = app.outlines["discover-package-list"].firstMatch
        assertExists(packageList, timeout: Self.elementTimeout, "Discover package list should appear")
        let searchField = app.searchFields["discover-search-field"].firstMatch
        assertExists(searchField, timeout: Self.elementTimeout, "Discover search should appear")

        assertHorizontallyContained(searchField, named: "Discover search", in: packageList)
    }

    func testPackageRowMetadataRemainsReadableInNarrowContentColumn() throws {
        let packageName = app.staticTexts["package-row-ripgrep"]
        assertExists(packageName, timeout: Self.launchTimeout, "Fixture package should appear")
        packageName.click()
        resizeMainWindow(toWidth: 920)

        let packageList = app.outlines["package-list"].firstMatch
        assertExists(packageList, timeout: Self.launchTimeout, "Package list should appear")
        XCTAssertLessThanOrEqual(
            packageList.frame.width,
            360,
            "The fixture must exercise a narrow package-list column"
        )

        let pinnedBadge = app.staticTexts["package-row-pinned-ripgrep"].firstMatch
        assertExists(pinnedBadge, timeout: Self.elementTimeout, "Pinned badge should appear")

        for badgeID in [
            "package-detail-source-badge",
            "package-detail-pinned-badge",
            "package-detail-outdated-badge"
        ] {
            let badge = app.descendants(matching: .any)[badgeID].firstMatch
            assertExists(badge, timeout: Self.elementTimeout, "\(badgeID) should appear")
            XCTAssertGreaterThan(
                badge.frame.width,
                badge.frame.height,
                "\(badgeID) should remain horizontal in a narrow detail column"
            )
            XCTAssertLessThanOrEqual(
                badge.frame.height,
                20,
                "\(badgeID) should remain compact in a narrow detail column"
            )
        }

        let upgradeAllButton = app.buttons["Upgrade All"].firstMatch
        assertExists(upgradeAllButton, timeout: Self.elementTimeout, "Upgrade All should appear")
        let searchField = app.searchFields["package-search-field"].firstMatch
        assertExists(searchField, timeout: Self.elementTimeout, "Package search should appear")
        assertHorizontallyContained(
            upgradeAllButton,
            named: "Upgrade All",
            in: packageList
        )
        assertHorizontallyContained(
            searchField,
            named: "Package search",
            in: packageList
        )

        XCTAssertGreaterThan(
            packageName.frame.width,
            packageName.frame.height,
            "Package names should remain on one line in a narrow content column"
        )
        XCTAssertGreaterThan(
            pinnedBadge.frame.width,
            pinnedBadge.frame.height,
            "Status badges should remain horizontal in a narrow content column"
        )
    }

    func testLongPackageVersionDoesNotDisplacePackageName() throws {
        app.terminate()
        app.launchEnvironment["BREWY_UI_LONG_PACKAGE_VERSION"] = "1"
        app.launch()
        app.activate()

        let sidebar = app.outlines.firstMatch
        assertExists(sidebar, timeout: Self.launchTimeout, "Sidebar should appear")
        sidebar.staticTexts["Casks"].click()

        let stablePackage = app.staticTexts["package-row-firefox"]
        assertExists(stablePackage, timeout: Self.elementTimeout, "Stable cask fixture should appear")
        stablePackage.click()
        resizeMainWindow(toWidth: 920)

        let packageList = app.outlines["package-list"].firstMatch
        assertExists(packageList, timeout: Self.elementTimeout, "Package list should appear")
        let window = app.windows.firstMatch
        assertExists(window, timeout: Self.elementTimeout, "Main window should appear")
        XCTAssertLessThanOrEqual(
            packageList.frame.width,
            window.frame.width / 2,
            "The fixture must exercise a constrained package-list column"
        )
        let packageName = app.staticTexts["package-row-claude"]
        assertExists(packageName, timeout: Self.elementTimeout, "Long-version fixture should appear")
        let version = app.staticTexts["package-row-version-claude"].firstMatch
        assertExists(version, timeout: Self.elementTimeout, "Package version should appear")

        assertHorizontallyContained(packageName, named: "Package name", in: packageList)
        assertHorizontallyContained(version, named: "Package version", in: packageList)
        XCTAssertGreaterThan(
            packageName.frame.width,
            packageName.frame.height,
            "A long version should not squeeze the package name out of the row"
        )
        XCTAssertLessThanOrEqual(
            packageName.frame.maxX,
            version.frame.minX,
            "The package name and version should not overlap"
        )
        XCTAssertEqual(
            version.value as? String,
            "1.32352.1,6c6aa595ae38b202d9e00c026dc94d3a6a42c332",
            "Accessibility should expose the complete version"
        )

        let longName = app.staticTexts["package-row-font-bitstream-vera-sans-mono-nerd-font"]
        assertExists(longName, timeout: Self.elementTimeout, "Long-name fixture should appear")
        let regularVersion = app.staticTexts[
            "package-row-version-font-bitstream-vera-sans-mono-nerd-font"
        ].firstMatch
        assertExists(regularVersion, timeout: Self.elementTimeout, "Regular version should appear")

        assertHorizontallyContained(longName, named: "Long package name", in: packageList)
        assertHorizontallyContained(regularVersion, named: "Regular version", in: packageList)
        XCTAssertGreaterThan(
            regularVersion.frame.width,
            regularVersion.frame.height,
            "A long package name should not reduce a regular version to one glyph"
        )
        XCTAssertLessThanOrEqual(
            longName.frame.maxX,
            regularVersion.frame.minX,
            "The long package name and regular version should not overlap"
        )
    }

    private func packageSearchField() -> XCUIElement {
        app.searchFields["package-search-field"].firstMatch
    }

    private func assertSearchField(_ searchField: XCUIElement, hasValue expectedValue: String) {
        let predicate = NSPredicate(format: "value == %@", expectedValue)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: searchField)
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: Self.elementTimeout),
            .completed,
            "Search field should contain '\(expectedValue)'"
        )
    }

    private func assertHorizontallyContained(
        _ element: XCUIElement,
        named name: String,
        in column: XCUIElement
    ) {
        XCTAssertGreaterThanOrEqual(
            element.frame.minX,
            column.frame.minX,
            "\(name) should remain inside its content column"
        )
        XCTAssertLessThanOrEqual(
            element.frame.maxX,
            column.frame.maxX,
            "\(name) should not enter the detail column"
        )
    }

    private func resizeMainWindow(toWidth width: CGFloat) {
        let window = app.windows.firstMatch
        assertExists(window, timeout: Self.launchTimeout, "Main window should appear")

        let widthDelta = width - window.frame.width
        guard abs(widthDelta) > 1 else { return }

        let rightEdge = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5))
        let destination = rightEdge.withOffset(CGVector(dx: widthDelta, dy: 0))
        rightEdge.press(forDuration: 0.1, thenDragTo: destination)
    }
}
