import Foundation

/// Mutable state threaded through a dependency-tree walk: the ancestor chain (for cycle detection)
/// and the remaining node budget (to bound total tree size).
private struct DependencyWalk {
    var ancestors: Set<String>
    var budget: Int
}

extension BrewService {
    /// Recursive reverse-dependency tree: walks upward through installed packages that depend on `name`.
    /// Use this to answer "where does this package come from?" — the leaves are the user-requested
    /// installs that ultimately pulled this in.
    /// `maxNodes` bounds the total node count so a widely-shared package (e.g. a hub like
    /// `ca-certificates`) can't generate an unbounded tree that stalls rendering.
    func reverseDependencyTree(for name: String, maxDepth: Int = 8, maxNodes: Int = 300) -> [DependencyTreeNode] {
        var walk = DependencyWalk(ancestors: [name], budget: maxNodes)
        return buildReverseTree(name: name, prefix: name, walk: &walk, remaining: maxDepth)
    }

    /// Recursive forward-dependency tree: walks downward through what `name` depends on.
    /// Children of a not-installed dep are omitted since we only know dependencies for installed packages.
    func forwardDependencyTree(for name: String, maxDepth: Int = 8, maxNodes: Int = 300) -> [DependencyTreeNode] {
        guard let pkg = allInstalled.first(where: { $0.name == name }) else { return [] }
        var walk = DependencyWalk(ancestors: [name], budget: maxNodes)
        // `allInstalled` can hold two entries with the same name (e.g. a `docker` formula and the
        // `docker` cask), which would trap `Dictionary(uniqueKeysWithValues:)`. Keep the first —
        // formulae precede casks, and brew dependencies resolve to formulae.
        let lookup = Dictionary(allInstalled.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        return buildForwardTree(deps: pkg.dependencies, prefix: name, lookup: lookup, walk: &walk, remaining: maxDepth)
    }

    private func buildReverseTree(
        name: String, prefix: String, walk: inout DependencyWalk, remaining: Int
    ) -> [DependencyTreeNode] {
        guard remaining > 0 else { return [] }
        var nodes: [DependencyTreeNode] = []
        for parent in dependents(of: name) {
            guard walk.budget > 0 else { break }
            walk.budget -= 1
            let path = "\(prefix)>\(parent.name)"
            let isCycle = walk.ancestors.contains(parent.name)
            let children: [DependencyTreeNode]?
            if isCycle {
                children = nil
            } else {
                walk.ancestors.insert(parent.name)
                let kids = buildReverseTree(name: parent.name, prefix: path, walk: &walk, remaining: remaining - 1)
                walk.ancestors.remove(parent.name)
                children = kids.isEmpty ? nil : kids
            }
            nodes.append(DependencyTreeNode(
                id: path, name: parent.name,
                isInstalled: true, installedOnRequest: parent.installedOnRequest,
                isCycle: isCycle, children: children
            ))
        }
        return nodes
    }

    private func buildForwardTree(
        deps: [String], prefix: String, lookup: [String: BrewPackage], walk: inout DependencyWalk, remaining: Int
    ) -> [DependencyTreeNode] {
        guard remaining > 0 else { return [] }
        var nodes: [DependencyTreeNode] = []
        for depName in deps {
            guard walk.budget > 0 else { break }
            walk.budget -= 1
            let path = "\(prefix)>\(depName)"
            let isCycle = walk.ancestors.contains(depName)
            let installedPkg = lookup[depName]
            let children: [DependencyTreeNode]?
            if !isCycle, let installedPkg {
                walk.ancestors.insert(depName)
                let kids = buildForwardTree(
                    deps: installedPkg.dependencies, prefix: path, lookup: lookup, walk: &walk, remaining: remaining - 1
                )
                walk.ancestors.remove(depName)
                children = kids.isEmpty ? nil : kids
            } else {
                children = nil
            }
            nodes.append(DependencyTreeNode(
                id: path, name: depName,
                isInstalled: installedPkg != nil,
                installedOnRequest: installedPkg?.installedOnRequest ?? false,
                isCycle: isCycle, children: children
            ))
        }
        return nodes
    }
}
