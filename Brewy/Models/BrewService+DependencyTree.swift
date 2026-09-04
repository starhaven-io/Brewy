import Foundation

/// Mutable state threaded through a dependency-tree walk: the ancestor chain (for cycle detection)
/// and the remaining node budget (to bound total tree size).
private struct DependencyWalk {
    var ancestors: Set<String>
    var budget: Int
}

extension BrewService {
    func dependents(of reference: PackageReference) -> [BrewPackage] {
        reverseDependencies[reference.id] ?? []
    }

    func dependents(of name: String, source: PackageSource = .formula) -> [BrewPackage] {
        dependents(of: PackageReference(name: name, source: source))
    }

    /// Recursive reverse-dependency tree: walks upward through installed packages that depend on `package`.
    /// Use this to answer "where does this package come from?" — the leaves are the user-requested
    /// installs that ultimately pulled this in.
    /// `maxNodes` bounds the total node count so a widely-shared package (e.g. a hub like
    /// `ca-certificates`) can't generate an unbounded tree that stalls rendering.
    func reverseDependencyTree(
        for package: BrewPackage,
        maxDepth: Int = 8,
        maxNodes: Int = 300
    ) -> [DependencyTreeNode] {
        reverseDependencyTree(
            for: PackageReference(name: package.name, source: package.source),
            maxDepth: maxDepth,
            maxNodes: maxNodes
        )
    }

    func reverseDependencyTree(
        for name: String,
        source: PackageSource = .formula,
        maxDepth: Int = 8,
        maxNodes: Int = 300
    ) -> [DependencyTreeNode] {
        reverseDependencyTree(
            for: PackageReference(name: name, source: source),
            maxDepth: maxDepth,
            maxNodes: maxNodes
        )
    }

    /// Recursive forward-dependency tree: walks downward through what `package` depends on.
    /// Children of a not-installed dep are omitted since we only know dependencies for installed packages.
    func forwardDependencyTree(
        for package: BrewPackage,
        maxDepth: Int = 8,
        maxNodes: Int = 300
    ) -> [DependencyTreeNode] {
        forwardDependencyTree(forID: package.id, maxDepth: maxDepth, maxNodes: maxNodes)
    }

    func forwardDependencyTree(
        for name: String,
        source: PackageSource = .formula,
        maxDepth: Int = 8,
        maxNodes: Int = 300
    ) -> [DependencyTreeNode] {
        forwardDependencyTree(
            forID: PackageReference(name: name, source: source).id,
            maxDepth: maxDepth,
            maxNodes: maxNodes
        )
    }

    private func buildReverseTree(
        reference: PackageReference, prefix: String, walk: inout DependencyWalk, remaining: Int
    ) -> [DependencyTreeNode] {
        guard remaining > 0 else { return [] }
        var nodes: [DependencyTreeNode] = []
        for parent in dependents(of: reference) {
            guard walk.budget > 0 else { break }
            walk.budget -= 1
            let path = "\(prefix)>\(parent.id)"
            let isCycle = walk.ancestors.contains(parent.id)
            let children: [DependencyTreeNode]?
            if isCycle {
                children = nil
            } else {
                walk.ancestors.insert(parent.id)
                let parentReference = PackageReference(name: parent.name, source: parent.source)
                let kids = buildReverseTree(
                    reference: parentReference,
                    prefix: path,
                    walk: &walk,
                    remaining: remaining - 1
                )
                walk.ancestors.remove(parent.id)
                children = kids.isEmpty ? nil : kids
            }
            nodes.append(DependencyTreeNode(
                id: path, name: parent.name, packageID: parent.id,
                isInstalled: true, installedOnRequest: parent.installedOnRequest,
                isCycle: isCycle, children: children
            ))
        }
        return nodes
    }

    private func buildForwardTree(
        dependencies: [PackageReference],
        prefix: String,
        lookup: [String: BrewPackage],
        walk: inout DependencyWalk,
        remaining: Int
    ) -> [DependencyTreeNode] {
        guard remaining > 0 else { return [] }
        var nodes: [DependencyTreeNode] = []
        for dependency in dependencies {
            guard walk.budget > 0 else { break }
            walk.budget -= 1
            let path = "\(prefix)>\(dependency.id)"
            let isCycle = walk.ancestors.contains(dependency.id)
            let installedPackage = lookup[dependency.id]
            let children: [DependencyTreeNode]?
            if !isCycle, let installedPackage {
                walk.ancestors.insert(dependency.id)
                let kids = buildForwardTree(
                    dependencies: installedPackage.dependencyReferences,
                    prefix: path,
                    lookup: lookup,
                    walk: &walk,
                    remaining: remaining - 1
                )
                walk.ancestors.remove(dependency.id)
                children = kids.isEmpty ? nil : kids
            } else {
                children = nil
            }
            nodes.append(DependencyTreeNode(
                id: path, name: dependency.name, packageID: installedPackage?.id,
                isInstalled: installedPackage != nil,
                installedOnRequest: installedPackage?.installedOnRequest ?? false,
                isCycle: isCycle, children: children
            ))
        }
        return nodes
    }

    private func reverseDependencyTree(
        for reference: PackageReference,
        maxDepth: Int,
        maxNodes: Int
    ) -> [DependencyTreeNode] {
        var walk = DependencyWalk(ancestors: [reference.id], budget: maxNodes)
        return buildReverseTree(
            reference: reference,
            prefix: reference.id,
            walk: &walk,
            remaining: maxDepth
        )
    }

    private func forwardDependencyTree(forID id: String, maxDepth: Int, maxNodes: Int) -> [DependencyTreeNode] {
        guard let package = allInstalled.first(where: { $0.id == id }) else { return [] }
        var walk = DependencyWalk(ancestors: [package.id], budget: maxNodes)
        let lookup = Dictionary(allInstalled.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return buildForwardTree(
            dependencies: package.dependencyReferences,
            prefix: package.id,
            lookup: lookup,
            walk: &walk,
            remaining: maxDepth
        )
    }
}
