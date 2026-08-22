import SwiftUI

struct ApplicationSecuritySection: View {
    @Environment(BrewService.self)
    private var brewService
    let package: BrewPackage
    @State private var loadState: LoadState = .idle
    @State private var refreshID = 0

    private var requestID: String {
        let applicationPath = brewService.installedApplicationURL(for: package)?.path ?? ""
        return "\(package.id)\u{0}\(package.version)\u{0}\(applicationPath)\u{0}\(refreshID)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Security Details")
                    .font(.headline)
                Spacer()
                if loadState != .idle, loadState != .loading {
                    Button("Check Again", systemImage: "arrow.clockwise") {
                        refreshID += 1
                    }
                    .controlSize(.small)
                    .accessibilityIdentifier("application-security-retry")
                }
            }

            switch loadState {
            case .idle:
                VStack(alignment: .leading, spacing: 8) {
                    Text("Check this app’s signature, Gatekeeper assessment, and notarization evidence.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Check Security", systemImage: "checkmark.shield") {
                        refreshID += 1
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("application-security-check")
                }
            case .loading:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                    Text("Checking this application…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Checking application security")
                .accessibilityIdentifier("application-security-loading")
            case .unavailable:
                Text("Brewy could not locate this application bundle. Refresh packages, then try again.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("application-security-unavailable")
            case .loaded(let details):
                ApplicationSecurityDetailsGrid(details: details)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Security Details")
        .accessibilityIdentifier("application-security-section")
        .task(id: requestID) {
            guard refreshID > 0 else { return }
            loadState = .loading
            let details = await brewService.applicationSecurityDetails(for: package)
            guard !Task.isCancelled else { return }
            loadState = details.map(LoadState.loaded) ?? .unavailable
        }
    }
}

extension ApplicationSecuritySection {
    private enum LoadState: Equatable {
        case idle
        case loading
        case unavailable
        case loaded(ApplicationSecurityDetails)
    }
}

private struct ApplicationSecurityDetailsGrid: View {
    let details: ApplicationSecurityDetails

    var body: some View {
        LazyVGrid(columns: [
            GridItem(.flexible(), alignment: .topLeading),
            GridItem(.flexible(), alignment: .topLeading)
        ], spacing: 10) {
            SecurityDetailField(
                label: "Code Signing",
                value: details.signingStatus.title,
                message: details.signingMessage,
                systemImage: details.signingStatus.systemImage,
                color: details.signingStatus.color,
                identifier: "application-security-signing"
            )
            SecurityDetailField(
                label: "Gatekeeper",
                value: details.gatekeeperStatus.title,
                message: details.gatekeeperMessage,
                systemImage: details.gatekeeperStatus.systemImage,
                color: details.gatekeeperStatus.color,
                identifier: "application-security-gatekeeper"
            )
            SecurityDetailField(
                label: "Notarization",
                value: details.notarizationStatus.title,
                systemImage: details.notarizationStatus.systemImage,
                color: details.notarizationStatus.color,
                identifier: "application-security-notarization"
            )
            if let source = details.gatekeeperSource {
                SecurityDetailField(
                    label: "Assessment Source",
                    value: source,
                    identifier: "application-security-source"
                )
            }
            if let signer = details.signer {
                SecurityDetailField(
                    label: "Signed By",
                    value: signer,
                    identifier: "application-security-signer"
                )
            }
            if let teamIdentifier = details.teamIdentifier {
                SecurityDetailField(
                    label: "Team ID",
                    value: teamIdentifier,
                    identifier: "application-security-team-id"
                )
            }
            SecurityDetailField(
                label: "Application",
                value: details.applicationURL.path,
                identifier: "application-security-path"
            )
        }
    }
}

private struct SecurityDetailField: View {
    let label: String
    let value: String
    var message: String?
    var systemImage: String?
    var color: Color = .primary
    let identifier: String

    private var accessibilityDescription: String {
        if let message {
            return "\(label): \(value). \(message)"
        }
        return "\(label): \(value)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .fontWeight(.medium)
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .accessibilityHidden(true)
                }
                Text(value)
                    .textSelection(.enabled)
            }
            .font(.callout)
            .foregroundStyle(color)
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityIdentifier(identifier)
    }
}

extension ApplicationSecurityDetails.SigningStatus {
    fileprivate var title: String {
        switch self {
        case .valid: "Signature Valid"
        case .unsigned: "Unsigned"
        case .invalid: "Signature Invalid"
        case .unavailable: "Unavailable"
        }
    }

    fileprivate var systemImage: String {
        switch self {
        case .valid: "checkmark.seal.fill"
        case .unsigned: "exclamationmark.triangle.fill"
        case .invalid: "xmark.seal.fill"
        case .unavailable: "questionmark.circle.fill"
        }
    }

    fileprivate var color: Color {
        switch self {
        case .valid: .green
        case .unsigned, .unavailable: .orange
        case .invalid: .red
        }
    }
}

extension ApplicationSecurityDetails.GatekeeperStatus {
    fileprivate var title: String {
        switch self {
        case .accepted: "Accepted"
        case .rejected: "Rejected"
        case .unavailable: "Unavailable"
        }
    }

    fileprivate var systemImage: String {
        switch self {
        case .accepted: "checkmark.shield.fill"
        case .rejected: "xmark.shield.fill"
        case .unavailable: "questionmark.circle.fill"
        }
    }

    fileprivate var color: Color {
        switch self {
        case .accepted: .green
        case .rejected: .red
        case .unavailable: .orange
        }
    }
}

extension ApplicationSecurityDetails.NotarizationStatus {
    fileprivate var title: String {
        switch self {
        case .stapledTicket: "Stapled Ticket"
        case .acceptedByGatekeeper: "Accepted by Gatekeeper"
        case .notReported: "Not Reported"
        }
    }

    fileprivate var systemImage: String {
        switch self {
        case .stapledTicket, .acceptedByGatekeeper: "checkmark.seal.fill"
        case .notReported: "minus.circle.fill"
        }
    }

    fileprivate var color: Color {
        switch self {
        case .stapledTicket, .acceptedByGatekeeper: .green
        case .notReported: .secondary
        }
    }
}
