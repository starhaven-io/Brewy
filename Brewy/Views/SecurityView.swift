import SwiftUI

private let securityScopeDescription =
    "Casks, Mac App Store apps, and apps installed outside Homebrew are not assessed."

struct SecurityView: View {
    @Environment(BrewService.self)
    private var brewService

    var body: some View {
        ZStack {
            if let scan = brewService.vulnerabilityScan {
                SecurityResultsList(scan: scan, error: brewService.vulnerabilityScanError)
            } else if brewService.isScanningVulnerabilities {
                SecurityScanningState()
            } else {
                SecurityUnavailableState(error: brewService.vulnerabilityScanError)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("security-pane")
        .navigationTitle("Security")
        .navigationSubtitle(navigationSubtitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(toolbarButtonTitle, systemImage: "arrow.clockwise") {
                    Task { await brewService.scanVulnerabilities() }
                }
                .labelStyle(.titleAndIcon)
                .accessibilityIdentifier("security-scan-button")
                .disabled(brewService.isScanningVulnerabilities)
                .help("Check installed Homebrew formulae for known vulnerabilities")
            }
        }
    }

    private var navigationSubtitle: String {
        if brewService.isScanningVulnerabilities { return "Scanning installed formulae" }
        guard let scan = brewService.vulnerabilityScan else { return "Not scanned" }
        if scan.openCount == 0 { return "No open findings returned" }
        return scan.openCount == 1 ? "1 open vulnerability" : "\(scan.openCount) open vulnerabilities"
    }

    private var toolbarButtonTitle: String {
        if brewService.isScanningVulnerabilities { return "Scanning..." }
        if brewService.vulnerabilityScan != nil { return "Scan Again" }
        if brewService.vulnerabilityScanError != nil { return "Retry Scan" }
        return "Run Scan"
    }
}

private struct SecurityResultsList: View {
    let scan: FormulaVulnerabilityScan
    let error: BrewError?

    var body: some View {
        List {
            SecurityScopeSection()

            if let error {
                SecurityMessageSection(
                    title: "Scan Failed",
                    message: error.localizedDescription,
                    systemImage: "xmark.octagon.fill",
                    color: .red
                )
            }

            SecurityScanContent(scan: scan)
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
    }
}

private struct SecurityScopeSection: View {
    var body: some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Installed Homebrew Formulae")
                        .font(.headline)
                    Text("Uses Homebrew’s vulnerability scanner and OSV data.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "terminal.fill")
                    .foregroundStyle(.green)
            }
        } footer: {
            Text(securityScopeDescription)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct SecurityScanningState: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text("Scanning Installed Formulae")
                .font(.headline)
            Text("Checking Homebrew formulae against known vulnerabilities.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("security-scanning-state")
    }
}

private struct SecurityUnavailableState: View {
    @Environment(BrewService.self)
    private var brewService

    let error: BrewError?

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            VStack(spacing: 6) {
                Text(description)
                    .textSelection(.enabled)
                Text(securityScopeDescription)
            }
        } actions: {
            Button(actionTitle) {
                Task { await brewService.scanVulnerabilities() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var title: String {
        error == nil ? "No Scan Yet" : "Scan Failed"
    }

    private var systemImage: String {
        error == nil ? "magnifyingglass" : "xmark.octagon"
    }

    private var description: String {
        error?.localizedDescription
            ?? "Homebrew queries OSV with upstream repository URLs and release tags when you run a scan."
    }

    private var actionTitle: String {
        error == nil ? "Run Vulnerability Scan" : "Retry Vulnerability Scan"
    }
}

private struct SecurityScanContent: View {
    let scan: FormulaVulnerabilityScan

    var body: some View {
        SecuritySummarySection(scan: scan)

        if let warning = scan.warning {
            SecurityMessageSection(
                title: "Homebrew Notice",
                message: warning,
                systemImage: "exclamationmark.triangle.fill",
                color: .orange
            )
        }

        if scan.openGroups.isEmpty {
            SecurityNoOpenFindingsSection()
        } else {
            SecurityFindingsSection(
                title: "Open Vulnerabilities",
                groups: scan.openGroups,
                resolution: .open
            )
        }

        if !scan.patchedGroups.isEmpty {
            SecurityFindingsSection(
                title: "Resolved by Formula Patches",
                groups: scan.patchedGroups,
                resolution: .patched
            )
        }

        SecurityCoverageSection()
    }
}

private struct SecuritySummarySection: View {
    let scan: FormulaVulnerabilityScan

    var body: some View {
        Section("Latest Scan") {
            HStack(spacing: 28) {
                SecurityMetric(
                    title: "Open",
                    count: scan.openCount,
                    systemImage: "exclamationmark.shield.fill",
                    color: scan.openCount == 0 ? .green : .red
                )
                SecurityMetric(
                    title: "Formula-patched",
                    count: scan.patchedCount,
                    systemImage: "checkmark.shield.fill",
                    color: .green
                )
                Spacer()
                Text(scan.scannedAt, format: .relative(presentation: .named))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct SecurityMetric: View {
    let title: String
    let count: Int
    let systemImage: String
    let color: Color

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text("\(count)")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(color)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct SecurityMessageSection: View {
    let title: String
    let message: String
    let systemImage: String
    let color: Color

    var body: some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .fontWeight(.medium)
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            } icon: {
                Image(systemName: systemImage)
                    .foregroundStyle(color)
            }
        }
    }
}

private struct SecurityNoOpenFindingsSection: View {
    var body: some View {
        Section {
            ContentUnavailableView(
                "No Open Vulnerabilities Returned",
                systemImage: "checkmark.shield",
                description: Text("Homebrew did not return any open findings in this scan.")
            )
        }
    }
}

private enum VulnerabilityResolution: Equatable {
    case open
    case patched
}

private struct SecurityFindingsSection: View {
    let title: String
    let groups: [FormulaVulnerabilityGroup]
    let resolution: VulnerabilityResolution

    var body: some View {
        Section(title) {
            ForEach(groups) { group in
                SecurityFormulaFindingRow(
                    group: group,
                    resolution: resolution
                )
            }
        }
    }
}

private struct SecurityFormulaFindingRow: View {
    let group: FormulaVulnerabilityGroup
    let resolution: VulnerabilityResolution

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.formula)
                        .font(.headline)
                        .textSelection(.enabled)
                    HStack(spacing: 12) {
                        Text("Installed version: \(group.version)")
                        Text("Scanned target: \(group.tag)")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                }
                Spacer()
                if let url = ExternalURLPolicy.url(from: group.repoURL) {
                    Link("Source", destination: url)
                        .font(.caption)
                }
                BrewyCountBadge(count: group.vulnerabilities.count)
            }

            ForEach(group.vulnerabilities) { vulnerability in
                SecurityVulnerabilityRow(
                    vulnerability: vulnerability,
                    resolution: resolution,
                    groupID: group.id
                )
            }
        }
        .padding(.vertical, 4)
    }
}

private struct SecurityVulnerabilityRow: View {
    let vulnerability: BrewVulnerability
    let resolution: VulnerabilityResolution
    let groupID: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            BrewyStatusBadge(vulnerability.severity.title, color: vulnerability.severity.color)
            VStack(alignment: .leading, spacing: 4) {
                if let url = vulnerability.advisoryURL {
                    Link(destination: url) {
                        HStack(spacing: 4) {
                            Text(vulnerability.id)
                                .fontWeight(.medium)
                            Image(systemName: "arrow.up.right")
                                .font(.caption2)
                        }
                    }
                } else {
                    Text(vulnerability.id)
                        .fontWeight(.medium)
                }

                if let summary = vulnerability.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                if !vulnerability.aliases.isEmpty {
                    Text("Also known as: \(vulnerability.aliases.joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }

                if !vulnerability.fixedVersions.isEmpty {
                    Text("Upstream fix boundary: \(vulnerability.fixedVersions.joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }

                if resolution == .patched {
                    Text("Resolved by a Homebrew formula patch")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("security-vulnerability-\(groupID)|\(vulnerability.id)")
    }
}

private struct SecurityCoverageSection: View {
    var body: some View {
        Section("Coverage") {
            Label(
                "The JSON report does not include checked or skipped formula counts.",
                systemImage: "info.circle"
            )
            Label(
                "An empty report means Homebrew returned no findings, not that every installed formula was assessed.",
                systemImage: "eye.trianglebadge.exclamationmark"
            )
        }
    }
}

extension VulnerabilitySeverity {
    var color: Color {
        switch self {
        case .critical: .red
        case .high: .orange
        case .medium: .yellow
        case .low: .blue
        case .unknown: .secondary
        }
    }
}
