@testable import Brewy
import Testing

@Suite("Menu Bar Package Items")
struct MenuBarPackageItemTests {
    @Test("Packages sort naturally by name and keep distinct sources with the same name")
    func sortedMixedSources() {
        let packages = [
            makePackage(name: "zsh"),
            makePackage(name: "tool10"),
            makePackage(name: "tool2"),
            makePackage(name: "same", source: .mas),
            makePackage(name: "same", source: .formula),
            makePackage(name: "same", source: .cask),
            makePackage(name: "Alpha", source: .cask)
        ]
        let expectedIDs = [
            "cask-Alpha", "cask-same", "formula-same", "mas-same", "formula-tool2", "formula-tool10", "formula-zsh"
        ]

        #expect(MenuBarPackageItem.sortedItems(from: packages).map(\.id) == expectedIDs)
        #expect(MenuBarPackageItem.sortedItems(from: packages.reversed()).map(\.id) == expectedIDs)
    }

    @Test("Rows identify each source and show available version changes")
    func sourceAndVersionLabels() {
        let packages = [
            makePackage(name: "same", source: .formula, isOutdated: true, installedVersion: "1.0", latestVersion: "2.0"),
            makePackage(name: "same", source: .cask, isOutdated: true, installedVersion: "3.0", latestVersion: "4.0"),
            makePackage(name: "same", source: .mas, isOutdated: true, installedVersion: "5.0")
        ]

        #expect(packages.map { MenuBarPackageItem(package: $0).title } == [
            "same (Formula): 1.0 → 2.0",
            "same (Cask): 3.0 → 4.0",
            "same (Mac App Store): 5.0"
        ])
    }

    @Test("Version changes update the row without changing its identity")
    func metadataChanges() {
        let original = MenuBarPackageItem(package: makePackage(name: "wget", isOutdated: true, latestVersion: "2.0"))
        let refreshed = MenuBarPackageItem(package: makePackage(name: "wget", isOutdated: true, latestVersion: "3.0"))

        #expect(original.id == refreshed.id)
        #expect(original.title == "wget (Formula): 1.0 → 2.0")
        #expect(refreshed.title == "wget (Formula): 1.0 → 3.0")
    }

    @Test("The menu includes every supplied update and handles an empty inventory")
    func completeInventory() {
        let packages = (1...100).map { makePackage(name: "package\($0)", isOutdated: true) }

        #expect(MenuBarPackageItem.sortedItems(from: packages).map(\.id) == packages.map(\.id))
        #expect(MenuBarPackageItem.sortedItems(from: []).isEmpty)
    }
}
