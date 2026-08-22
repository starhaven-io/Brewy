import Foundation

struct ApplicationSecurityDetails: Equatable, Sendable {
    enum SigningStatus: Equatable, Sendable {
        case valid
        case unsigned
        case invalid
        case unavailable
    }

    enum GatekeeperStatus: Equatable, Sendable {
        case accepted
        case rejected
        case unavailable
    }

    enum NotarizationStatus: Equatable, Sendable {
        case stapledTicket
        case acceptedByGatekeeper
        case notReported
    }

    let applicationURL: URL
    let signingStatus: SigningStatus
    let signingMessage: String?
    let signer: String?
    let teamIdentifier: String?
    let gatekeeperStatus: GatekeeperStatus
    let gatekeeperSource: String?
    let gatekeeperMessage: String?
    let notarizationStatus: NotarizationStatus
}

enum ApplicationSecurityParser {
    static func parse(
        applicationURL: URL,
        signingMetadata: CommandResult,
        signingVerification: CommandResult,
        gatekeeperAssessment: CommandResult
    ) -> ApplicationSecurityDetails {
        let metadataOutput = rawOutput(for: signingMetadata)
        let verificationOutput = rawOutput(for: signingVerification)
        let gatekeeperOutput = rawOutput(for: gatekeeperAssessment)
        let signingStatus = signingStatus(
            verification: signingVerification,
            output: verificationOutput
        )
        let gatekeeperStatus = gatekeeperStatus(
            assessment: gatekeeperAssessment,
            output: gatekeeperOutput
        )
        let gatekeeperSource = value(for: "source", in: gatekeeperOutput)
        let hasValidSignature = signingStatus == .valid
        let signer = hasValidSignature ? signingIdentity(in: metadataOutput, gatekeeperOutput: gatekeeperOutput) : nil
        let teamIdentifier = hasValidSignature ? normalizedTeamIdentifier(in: metadataOutput) : nil

        return ApplicationSecurityDetails(
            applicationURL: applicationURL,
            signingStatus: signingStatus,
            signingMessage: signingMessage(
                for: signingStatus,
                output: verificationOutput,
                applicationPath: applicationURL.path
            ),
            signer: signer,
            teamIdentifier: teamIdentifier,
            gatekeeperStatus: gatekeeperStatus,
            gatekeeperSource: gatekeeperSource,
            gatekeeperMessage: gatekeeperMessage(
                for: gatekeeperStatus,
                output: gatekeeperOutput,
                applicationPath: applicationURL.path
            ),
            notarizationStatus: notarizationStatus(
                signingStatus: signingStatus,
                metadataOutput: metadataOutput,
                gatekeeperStatus: gatekeeperStatus,
                gatekeeperSource: gatekeeperSource
            )
        )
    }

    private static func signingStatus(
        verification: CommandResult,
        output: String
    ) -> ApplicationSecurityDetails.SigningStatus {
        if verification.success {
            return .valid
        }
        let lowercaseOutput = output.lowercased()
        if lowercaseOutput.contains("not signed at all") {
            return .unsigned
        }
        if verification.cancelled
            || lowercaseOutput.contains("timed out")
            || lowercaseOutput.contains("failed to run")
            || lowercaseOutput.contains("no such file")
            || lowercaseOutput.contains("does not exist")
            || lowercaseOutput.contains("failed to launch process") {
            return .unavailable
        }
        return .invalid
    }

    private static func gatekeeperStatus(
        assessment: CommandResult,
        output: String
    ) -> ApplicationSecurityDetails.GatekeeperStatus {
        if assessment.success {
            return .accepted
        }
        if assessment.cancelled {
            return .unavailable
        }
        if assessment.exitCode == 3 || output.localizedCaseInsensitiveContains("rejected") {
            return .rejected
        }
        return .unavailable
    }

    private static func signingIdentity(in metadataOutput: String, gatekeeperOutput: String) -> String? {
        if let authority = value(for: "Authority", in: metadataOutput) {
            return authority
        }
        if value(for: "Signature", in: metadataOutput)?.lowercased() == "adhoc" {
            return "Ad Hoc"
        }
        return value(for: "origin", in: gatekeeperOutput)
    }

    private static func normalizedTeamIdentifier(in output: String) -> String? {
        guard let identifier = value(for: "TeamIdentifier", in: output),
              !identifier.isEmpty,
              identifier.lowercased() != "not set" else {
            return nil
        }
        return identifier
    }

    private static func notarizationStatus(
        signingStatus: ApplicationSecurityDetails.SigningStatus,
        metadataOutput: String,
        gatekeeperStatus: ApplicationSecurityDetails.GatekeeperStatus,
        gatekeeperSource: String?
    ) -> ApplicationSecurityDetails.NotarizationStatus {
        if signingStatus == .valid,
           value(for: "Notarization Ticket", in: metadataOutput)?.lowercased() == "stapled" {
            return .stapledTicket
        }
        if gatekeeperStatus == .accepted,
           gatekeeperSource?.lowercased().hasPrefix("notarized ") == true {
            return .acceptedByGatekeeper
        }
        return .notReported
    }

    private static func signingMessage(
        for status: ApplicationSecurityDetails.SigningStatus,
        output: String,
        applicationPath: String
    ) -> String? {
        switch status {
        case .invalid, .unavailable:
            diagnostic(from: output, applicationPath: applicationPath)
        case .valid, .unsigned:
            nil
        }
    }

    private static func gatekeeperMessage(
        for status: ApplicationSecurityDetails.GatekeeperStatus,
        output: String,
        applicationPath: String
    ) -> String? {
        switch status {
        case .rejected, .unavailable:
            guard let message = diagnostic(from: output, applicationPath: applicationPath) else { return nil }
            let statusWord = status == .rejected ? "Rejected" : "Unavailable"
            return message.localizedCaseInsensitiveCompare(statusWord) == .orderedSame ? nil : message
        case .accepted:
            return nil
        }
    }

    private static func rawOutput(for result: CommandResult) -> String {
        let rawStreams = [result.standardOutput, result.standardError]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        if !result.success, !result.output.isEmpty {
            return result.output
        }
        return rawStreams.isEmpty ? result.output : rawStreams
    }

    private static func value(for key: String, in output: String) -> String? {
        let prefix = "\(key)="
        return output.split(whereSeparator: \.isNewline).lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }
    }

    private static func diagnostic(from output: String, applicationPath: String) -> String? {
        let candidates = output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { line in
                let lowercaseLine = line.lowercased()
                return !line.isEmpty
                    && !lowercaseLine.hasPrefix("source=")
                    && !lowercaseLine.hasPrefix("origin=")
                    && !lowercaseLine.hasPrefix("--prepared:")
                    && !lowercaseLine.hasPrefix("--validated:")
                    && !lowercaseLine.hasPrefix("file modified:")
                    && !lowercaseLine.hasPrefix("in subcomponent:")
            }
        let verdictPrefix = "\(applicationPath):"
        guard var diagnostic = candidates.first(where: { $0.hasPrefix(verdictPrefix) })
            ?? candidates.first else { return nil }
        if diagnostic.hasPrefix(verdictPrefix) {
            diagnostic = String(diagnostic.dropFirst(verdictPrefix.count))
                .trimmingCharacters(in: .whitespaces)
        } else if let separator = diagnostic.firstIndex(of: ":") {
            diagnostic = diagnostic[diagnostic.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
        }
        guard let first = diagnostic.first else { return nil }
        return first.uppercased() + diagnostic.dropFirst()
    }
}
