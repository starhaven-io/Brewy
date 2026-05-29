import SwiftUI

struct DependencyTreeSection: View {
    @Environment(BrewService.self)
    private var brewService
    let package: BrewPackage

    @State private var pulledInExpanded = false
    @State private var pullsInExpanded = false
    @State private var reverse: [DependencyTreeNode] = []
    @State private var forward: [DependencyTreeNode] = []

    var body: some View {
        Group {
            if !reverse.isEmpty || !forward.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Dependency Tree")
                        .font(.headline)

                    if !reverse.isEmpty {
                        DependencyTreeDisclosure(
                            title: "Pulled in by",
                            help: "Installed packages that depend on \(package.name), recursively up to the user-requested install.",
                            nodes: reverse,
                            isExpanded: $pulledInExpanded
                        )
                    }

                    if !forward.isEmpty {
                        DependencyTreeDisclosure(
                            title: "Pulls in",
                            help: "What \(package.name) depends on, recursively.",
                            nodes: forward,
                            isExpanded: $pullsInExpanded
                        )
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
            }
        }
        .task(id: package.id) {
            reverse = brewService.reverseDependencyTree(for: package.name)
            forward = brewService.forwardDependencyTree(for: package.name)
        }
    }
}

private struct DependencyTreeDisclosure: View {
    let title: String
    let help: String
    let nodes: [DependencyTreeNode]
    @Binding var isExpanded: Bool

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 2) {
                DependencyTreeRows(nodes: nodes, depth: 0)
            }
            .padding(.top, 6)
        } label: {
            HStack(spacing: 6) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text("\(nodes.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.secondary.opacity(0.15), in: .capsule)
            }
            .help(help)
        }
    }
}

private struct DependencyTreeRows: View {
    let nodes: [DependencyTreeNode]
    let depth: Int

    var body: some View {
        ForEach(nodes) { node in
            DependencyTreeRow(node: node)
                .padding(.leading, CGFloat(depth) * 14)
            if let children = node.children, !children.isEmpty {
                Self(nodes: children, depth: depth + 1)
            }
        }
    }
}

private struct DependencyTreeRow: View {
    @Environment(\.selectPackage)
    private var selectPackage
    let node: DependencyTreeNode

    var body: some View {
        HStack(spacing: 6) {
            Button {
                if node.isInstalled { selectPackage(node.name) }
            } label: {
                Text(node.name)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(node.isInstalled ? Color.blue : Color.secondary)
            }
            .buttonStyle(.plain)
            .disabled(!node.isInstalled)
            .help(node.isInstalled ? "Go to \(node.name)" : "\(node.name) (not installed)")

            if node.installedOnRequest {
                Text("requested")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.orange.opacity(0.12), in: .capsule)
                    .help("Installed on request by the user")
            }
            if node.isCycle {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("Already shown above in this chain")
            }
        }
    }
}
