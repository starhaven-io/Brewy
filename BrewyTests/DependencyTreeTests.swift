@testable import Brewy
import Foundation
import Testing

private func makePackage(
    name: String,
    installedOnRequest: Bool = true,
    dependencies: [String] = [],
    source: PackageSource = .formula,
    dependencyReferences: [PackageReference]? = nil
) -> BrewPackage {
    BrewPackage(
        id: "\(source.rawValue)-\(name)", name: name, version: "1.0",
        description: "", homepage: "",
        isInstalled: true, isOutdated: false,
        installedVersion: "1.0", latestVersion: nil,
        source: source, pinned: false,
        installedOnRequest: installedOnRequest,
        dependencies: dependencies,
        dependencyReferences: dependencyReferences
    )
}

private func countNodes(_ nodes: [DependencyTreeNode]) -> Int {
    nodes.reduce(0) { $0 + 1 + countNodes($1.children ?? []) }
}

@Suite("BrewService Dependency Tree")
@MainActor
struct BrewServiceDependencyTreeTests {

    @Test("Reverse tree walks up to the user-requested install")
    func reverseTreeChain() {
        let service = BrewService()
        service.installedFormulae = [
            makePackage(name: "openssl", installedOnRequest: false),
            makePackage(name: "curl", installedOnRequest: false, dependencies: ["openssl"]),
            makePackage(name: "wget", installedOnRequest: true, dependencies: ["curl"])
        ]

        let tree = service.reverseDependencyTree(for: "openssl")
        #expect(tree.count == 1)
        #expect(tree[0].name == "curl")
        let curlChildren = tree[0].children ?? []
        #expect(curlChildren.count == 1)
        #expect(curlChildren[0].name == "wget")
        #expect(curlChildren[0].installedOnRequest == true)
        #expect(curlChildren[0].children == nil)
    }

    @Test("Reverse tree is empty for top-level packages")
    func reverseTreeEmpty() {
        let service = BrewService()
        service.installedFormulae = [makePackage(name: "wget")]
        #expect(service.reverseDependencyTree(for: "wget").isEmpty)
    }

    @Test("Reverse tree handles diamond dependencies via path-based IDs")
    func reverseTreeDiamond() {
        let service = BrewService()
        service.installedFormulae = [
            makePackage(name: "z", installedOnRequest: false),
            makePackage(name: "a", installedOnRequest: false, dependencies: ["z"]),
            makePackage(name: "b", installedOnRequest: false, dependencies: ["z"]),
            makePackage(name: "top", installedOnRequest: true, dependencies: ["a", "b"])
        ]

        let tree = service.reverseDependencyTree(for: "z")
        #expect(tree.count == 2)
        let ids = Set(tree.flatMap { node -> [String] in
            [node.id] + (node.children?.map(\.id) ?? [])
        })
        #expect(ids.contains("formula-z>formula-a"))
        #expect(ids.contains("formula-z>formula-b"))
        #expect(ids.contains("formula-z>formula-a>formula-top"))
        #expect(ids.contains("formula-z>formula-b>formula-top"))
    }

    @Test("Reverse tree guards against cycles in the ancestor chain")
    func reverseTreeCycleGuard() {
        let service = BrewService()
        // Fabricated cycle: A→B→A. Brew shouldn't produce this, but the guard protects us.
        service.installedFormulae = [
            makePackage(name: "a", dependencies: ["b"]),
            makePackage(name: "b", dependencies: ["a"])
        ]

        let tree = service.reverseDependencyTree(for: "a")
        #expect(tree.count == 1)
        #expect(tree[0].name == "b")
        let bChildren = tree[0].children ?? []
        #expect(bChildren.count == 1)
        #expect(bChildren[0].name == "a")
        #expect(bChildren[0].isCycle == true)
        #expect(bChildren[0].children == nil)
    }

    @Test("Forward tree walks down the dependencies of the package")
    func forwardTreeChain() {
        let service = BrewService()
        service.installedFormulae = [
            makePackage(name: "openssl"),
            makePackage(name: "curl", dependencies: ["openssl"]),
            makePackage(name: "wget", dependencies: ["curl"])
        ]

        let tree = service.forwardDependencyTree(for: "wget")
        #expect(tree.count == 1)
        #expect(tree[0].name == "curl")
        #expect(tree[0].isInstalled == true)
        let curlDeps = tree[0].children ?? []
        #expect(curlDeps.count == 1)
        #expect(curlDeps[0].name == "openssl")
        #expect(curlDeps[0].children == nil)
    }

    @Test("Forward tree marks uninstalled deps as not installed and stops recursing")
    func forwardTreeUninstalledDep() {
        let service = BrewService()
        service.installedFormulae = [
            makePackage(name: "wget", dependencies: ["missing-dep"])
        ]

        let tree = service.forwardDependencyTree(for: "wget")
        #expect(tree.count == 1)
        #expect(tree[0].name == "missing-dep")
        #expect(tree[0].isInstalled == false)
        #expect(tree[0].children == nil)
    }

    @Test("Forward tree returns empty for non-installed root")
    func forwardTreeUnknownRoot() {
        let service = BrewService()
        service.installedFormulae = [makePackage(name: "wget")]
        #expect(service.forwardDependencyTree(for: "nonexistent").isEmpty)
    }

    @Test("maxDepth cuts off deep recursion")
    func maxDepthCutoff() {
        let service = BrewService()
        service.installedFormulae = [
            makePackage(name: "l0", dependencies: ["l1"]),
            makePackage(name: "l1", dependencies: ["l2"]),
            makePackage(name: "l2", dependencies: ["l3"]),
            makePackage(name: "l3")
        ]

        let depth1 = service.forwardDependencyTree(for: "l0", maxDepth: 1)
        #expect(depth1.count == 1)
        #expect(depth1[0].name == "l1")
        #expect(depth1[0].children == nil)
    }

    @Test("Forward tree does not trap when a formula and cask share a name")
    func forwardTreeDuplicateNameDoesNotTrap() {
        let service = BrewService()
        service.installedFormulae = [
            makePackage(name: "docker", dependencies: ["openssl"]),
            makePackage(name: "openssl")
        ]
        // A same-named cask is a real configuration (docker CLI formula + Docker Desktop cask).
        service.installedCasks = [
            BrewPackage(
                id: "cask-docker", name: "docker", version: "1.0",
                description: "", homepage: "",
                isInstalled: true, isOutdated: false,
                installedVersion: "1.0", latestVersion: nil,
                source: .cask, pinned: false,
                installedOnRequest: true, dependencies: []
            )
        ]

        let tree = service.forwardDependencyTree(for: "docker")
        #expect(tree.count == 1)
        #expect(tree[0].name == "openssl")
        #expect(service.forwardDependencyTree(for: "docker", source: .cask).isEmpty)
    }

    @Test("Dependency trees preserve formula and cask identity for duplicate names")
    func dependencyTreesPreservePackageSource() {
        let formulaShared = makePackage(name: "shared", source: .formula)
        let caskShared = makePackage(name: "shared", source: .cask)
        let formulaParent = makePackage(name: "formula-parent", dependencies: ["shared"])
        let caskParent = makePackage(
            name: "cask-parent",
            dependencies: ["shared"],
            source: .cask,
            dependencyReferences: [PackageReference(name: "shared", source: .cask)]
        )
        let service = BrewService()
        service.installedFormulae = [formulaShared, formulaParent]
        service.installedCasks = [caskShared, caskParent]

        let formulaParents = service.reverseDependencyTree(for: formulaShared)
        let caskParents = service.reverseDependencyTree(for: caskShared)
        let caskDependencies = service.forwardDependencyTree(for: caskParent)

        #expect(formulaParents.map(\.packageID) == [formulaParent.id])
        #expect(caskParents.map(\.packageID) == [caskParent.id])
        #expect(caskDependencies.map(\.packageID) == [caskShared.id])
    }

    @Test("maxNodes bounds the total node count for hub packages")
    func maxNodesCap() {
        let service = BrewService()
        var packages = [makePackage(name: "root", dependencies: (0..<50).map { "dep\($0)" })]
        for index in 0..<50 {
            packages.append(makePackage(name: "dep\(index)"))
        }
        service.installedFormulae = packages

        let tree = service.forwardDependencyTree(for: "root", maxNodes: 10)
        #expect(!tree.isEmpty)
        #expect(countNodes(tree) <= 10)
    }
}
