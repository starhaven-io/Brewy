import Foundation

struct MenuBarPackageItem: Identifiable {
    let id: String
    let title: String

    init(package: BrewPackage) {
        id = package.id
        title = "\(package.name) (\(package.source.brewyDisplayName)): \(package.displayVersion)"
    }

    static func sortedItems(from packages: [BrewPackage]) -> [Self] {
        packages.sorted { lhs, rhs in
            let order = lhs.name.localizedStandardCompare(rhs.name)
            return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
        }.map { Self(package: $0) }
    }
}
