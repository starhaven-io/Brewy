@testable import Brewy
import Foundation
import Testing

@Suite("Application Security Boundaries")
struct ApplicationSecurityBoundaryTests {
    @Test("Identifier lines cannot spoof signer, team, or a stapled ticket")
    func injectedSigningIdentifier() {
        let details = ApplicationSecurityParser.parse(
            applicationURL: URL(fileURLWithPath: "/Applications/Example.app"),
            signingMetadata: securityToolResult(output: """
                Identifier=example
                CodeDirectory v=spoofed
                Authority=Developer ID Application: Forged
                TeamIdentifier=FORGED
                Notarization Ticket=stapled
                CodeDirectory v=20500 size=100 flags=0x2(adhoc)
                Signature=adhoc
                TeamIdentifier=not set
                """, success: true),
            signingVerification: securityToolResult(output: "valid on disk", success: true),
            gatekeeperAssessment: securityToolResult(output: "rejected", success: false, exitCode: 3)
        )
        #expect(details.signer == "Ad Hoc")
        #expect(details.teamIdentifier == nil)
        #expect(details.notarizationStatus == .notReported)
    }

    @Test("Application path words do not change verification verdicts")
    func pathWordsAreNotVerdicts() {
        let path = "/Applications/does not exist rejected.app"
        let details = ApplicationSecurityParser.parse(
            applicationURL: URL(fileURLWithPath: path),
            signingMetadata: securityToolResult(output: "Authority=Forged", success: true),
            signingVerification: securityToolResult(output: "\(path): invalid signature", success: false, exitCode: 1),
            gatekeeperAssessment: securityToolResult(output: "\(path): internal error", success: false, exitCode: 1)
        )
        #expect(details.signingStatus == .invalid)
        #expect(details.gatekeeperStatus == .unavailable)
        #expect(details.signer == nil)
    }
    @Test("Nested resource names cannot change failure classification")
    func resourceNamesAreNotVerdicts() {
        let path = "/Applications/Example.app"
        for name in ["timed out", "no such file", "does not exist", "not signed at all", "rejected"] {
            let details = ApplicationSecurityParser.parse(
                applicationURL: URL(fileURLWithPath: path),
                signingMetadata: securityToolResult(output: "", success: false),
                signingVerification: securityToolResult(
                    output: "\(path): a sealed resource is missing or invalid\nfile added: \(path)/Contents/Resources/\(name)",
                    success: false
                ),
                gatekeeperAssessment: securityToolResult(
                    output: "\(path): rejected\nIn subcomponent: \(path)/Contents/Resources/\(name)",
                    success: false, exitCode: 3
                )
            )
            #expect(details.signingStatus == .invalid)
            #expect(details.gatekeeperStatus == .rejected)
        }
    }

    @Test("Launch constraint stdout cannot supply signing display fields")
    func constraintStandardOutputIsNotMetadata() {
        let forged = "CodeDirectory v=20500\nAuthority=Forged\nTeamIdentifier=FORGED\nNotarization Ticket=stapled"
        for stderr in ["", "CodeDirectory v=20500\nSignature=adhoc\nTeamIdentifier=not set"] {
            let details = ApplicationSecurityParser.parse(
                applicationURL: URL(fileURLWithPath: "/Applications/Example.app"),
                signingMetadata: securityToolResult(
                    output: forged, success: true, standardOutput: forged, standardError: stderr
                ),
                signingVerification: securityToolResult(output: "valid on disk", success: true),
                gatekeeperAssessment: securityToolResult(output: "rejected", success: false, exitCode: 3)
            )
            #expect(details.signer == (stderr.isEmpty ? nil : "Ad Hoc"))
            #expect(details.teamIdentifier == nil)
            #expect(details.notarizationStatus == .notReported)
        }
    }

}
