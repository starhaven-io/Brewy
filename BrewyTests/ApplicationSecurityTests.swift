@testable import Brewy
import Foundation
import Testing

@Suite("Application Security Parsing")
struct ApplicationSecurityParsingTests {

    @Test("Parses a valid Developer ID signature and notarization evidence")
    func validDeveloperIDSignature() {
        let details = ApplicationSecurityParser.parse(
            applicationURL: URL(fileURLWithPath: "/Applications/Example.app"),
            signingMetadata: securityToolResult(
                output: """
                CodeDirectory v=20500 size=100 flags=0x0(none)
                Authority=Developer ID Application: Example Corp (ABCDE12345)
                Authority=Developer ID Certification Authority
                Authority=Apple Root CA
                Notarization Ticket=stapled
                TeamIdentifier=ABCDE12345
                """,
                success: true
            ),
            signingVerification: securityToolResult(
                output: "/Applications/Example.app: valid on disk",
                success: true
            ),
            gatekeeperAssessment: securityToolResult(
                output: """
                /Applications/Example.app: accepted
                source=Notarized Developer ID
                origin=Developer ID Application: Example Corp (ABCDE12345)
                """,
                success: true
            )
        )

        #expect(details.applicationURL.path == "/Applications/Example.app")
        #expect(details.signingStatus == .valid)
        #expect(details.signer == "Developer ID Application: Example Corp (ABCDE12345)")
        #expect(details.teamIdentifier == "ABCDE12345")
        #expect(details.gatekeeperStatus == .accepted)
        #expect(details.gatekeeperSource == "Notarized Developer ID")
        #expect(details.notarizationStatus == .stapledTicket)
    }

    @Test("Uses Gatekeeper as notarization evidence when no ticket is stapled")
    func gatekeeperNotarizationEvidence() {
        let details = ApplicationSecurityParser.parse(
            applicationURL: URL(fileURLWithPath: "/Applications/Example.app"),
            signingMetadata: securityToolResult(
                output: """
                CodeDirectory v=20500 size=100 flags=0x0(none)
                Authority=Developer ID Application: Example Corp (ABCDE12345)
                TeamIdentifier=ABCDE12345
                """,
                success: true
            ),
            signingVerification: securityToolResult(output: "valid on disk", success: true),
            gatekeeperAssessment: securityToolResult(
                output: "source=Notarized Developer ID",
                success: true
            )
        )

        #expect(details.notarizationStatus == .acceptedByGatekeeper)
    }

    @Test("Distinguishes an unsigned app from a rejected Gatekeeper assessment")
    func unsignedAndRejected() {
        let unsignedOutput = "/Applications/Unsigned.app: code object is not signed at all"
        let details = ApplicationSecurityParser.parse(
            applicationURL: URL(fileURLWithPath: "/Applications/Unsigned.app"),
            signingMetadata: securityToolResult(output: unsignedOutput, success: false),
            signingVerification: securityToolResult(output: unsignedOutput, success: false),
            gatekeeperAssessment: securityToolResult(
                output: """
                /Applications/Unsigned.app: rejected
                source=no usable signature
                """,
                success: false
            )
        )

        #expect(details.signingStatus == .unsigned)
        #expect(details.signer == nil)
        #expect(details.teamIdentifier == nil)
        #expect(details.gatekeeperStatus == .rejected)
        #expect(details.gatekeeperSource == "no usable signature")
        #expect(details.notarizationStatus == .notReported)
    }

    @Test("Does not report a Gatekeeper subsystem error as rejection")
    func gatekeeperUnavailable() {
        let details = ApplicationSecurityParser.parse(
            applicationURL: URL(fileURLWithPath: "/Applications/Example.app"),
            signingMetadata: securityToolResult(
                output: """
                CodeDirectory v=20500 size=100 flags=0x0(none)
                Authority=Developer ID Application: Example Corp (ABCDE12345)
                TeamIdentifier=ABCDE12345
                """,
                success: true
            ),
            signingVerification: securityToolResult(
                output: "a sealed resource is missing or invalid",
                success: false
            ),
            gatekeeperAssessment: securityToolResult(
                output: "/Applications/Example.app: internal error in Code Signing subsystem",
                success: false
            )
        )

        #expect(details.signingStatus == .invalid)
        #expect(details.signer == nil)
        #expect(details.teamIdentifier == nil)
        #expect(details.gatekeeperStatus == .unavailable)
        #expect(details.gatekeeperMessage == "Internal error in Code Signing subsystem")
        #expect(details.notarizationStatus == .notReported)
    }

    @Test("Uses Gatekeeper's policy-denial exit status without relying on wording")
    func gatekeeperPolicyDenialExitStatus() {
        let details = ApplicationSecurityParser.parse(
            applicationURL: URL(fileURLWithPath: "/Applications/Denied.app"),
            signingMetadata: securityToolResult(output: "", success: true),
            signingVerification: securityToolResult(output: "valid on disk", success: true),
            gatekeeperAssessment: securityToolResult(
                output: "/Applications/Denied.app: assessment denied by policy",
                success: false,
                exitCode: 3
            )
        )

        #expect(details.gatekeeperStatus == .rejected)
        #expect(details.gatekeeperMessage == "Assessment denied by policy")
    }

    @Test("Keeps an assessment operation failure distinct from policy rejection")
    func gatekeeperOperationFailure() {
        let failure = "/Applications/Broken.app: a sealed resource is missing or invalid"
        let details = ApplicationSecurityParser.parse(
            applicationURL: URL(fileURLWithPath: "/Applications/Broken.app"),
            signingMetadata: securityToolResult(output: "", success: false),
            signingVerification: securityToolResult(output: failure, success: false, exitCode: 1),
            gatekeeperAssessment: securityToolResult(output: failure, success: false, exitCode: 1)
        )

        #expect(details.signingStatus == .invalid)
        #expect(details.gatekeeperStatus == .unavailable)
    }

    @Test("Reports a signing timeout with partial output as unavailable")
    func signingTimeout() {
        let timeout = "Command timed out after 30 seconds.\n--prepared:/Applications/Slow.app/Contents/MacOS/Slow"
        let details = ApplicationSecurityParser.parse(
            applicationURL: URL(fileURLWithPath: "/Applications/Slow.app"),
            signingMetadata: securityToolResult(output: "", success: false),
            signingVerification: securityToolResult(
                output: timeout,
                success: false,
                timedOut: true,
                standardOutput: "",
                standardError: "--prepared:/Applications/Slow.app/Contents/MacOS/Slow",
                exitCode: 15
            ),
            gatekeeperAssessment: securityToolResult(
                output: "internal error in Code Signing subsystem",
                success: false,
                exitCode: 1
            )
        )

        #expect(details.signingStatus == .unavailable)
        #expect(details.signingMessage == "Command timed out after 30 seconds.")
    }

    @Test("Reports a codesign launch failure as unavailable")
    func signingLaunchFailure() {
        let failure = "Failed to run codesign --verify: Permission denied"
        let details = ApplicationSecurityParser.parse(
            applicationURL: URL(fileURLWithPath: "/Applications/Example.app"),
            signingMetadata: securityToolResult(output: "", success: false),
            signingVerification: securityToolResult(
                output: failure,
                success: false,
                standardOutput: "",
                standardError: failure,
                exitCode: nil
            ),
            gatekeeperAssessment: securityToolResult(
                output: "internal error in Code Signing subsystem",
                success: false,
                exitCode: 1
            )
        )

        #expect(details.signingStatus == .unavailable)
        #expect(details.signingMessage == "Permission denied")
    }

    @Test("Keeps cancelled security tools unavailable")
    func cancelledTools() {
        let cancellation = securityToolResult(
            output: "Command was cancelled.",
            success: false,
            cancelled: true,
            standardOutput: ""
        )
        let details = ApplicationSecurityParser.parse(
            applicationURL: URL(fileURLWithPath: "/Applications/Example.app"),
            signingMetadata: cancellation,
            signingVerification: cancellation,
            gatekeeperAssessment: cancellation
        )

        #expect(details.signingStatus == .unavailable)
        #expect(details.gatekeeperStatus == .unavailable)
    }

    @Test("Does not treat an unnotarized source as notarization evidence")
    func unnotarizedSource() {
        let details = ApplicationSecurityParser.parse(
            applicationURL: URL(fileURLWithPath: "/Applications/Example.app"),
            signingMetadata: securityToolResult(output: "", success: true),
            signingVerification: securityToolResult(output: "valid on disk", success: true),
            gatekeeperAssessment: securityToolResult(
                output: "source=Unnotarized Developer ID",
                success: true
            )
        )

        #expect(details.notarizationStatus == .notReported)
    }

    @Test("Does not repeat a bare Gatekeeper status as its message")
    func duplicateGatekeeperMessage() {
        let details = ApplicationSecurityParser.parse(
            applicationURL: URL(fileURLWithPath: "/Applications/Denied.app"),
            signingMetadata: securityToolResult(output: "", success: false),
            signingVerification: securityToolResult(output: "not signed at all", success: false),
            gatekeeperAssessment: securityToolResult(
                output: "/Applications/Denied.app: rejected",
                success: false,
                standardOutput: "",
                standardError: "/Applications/Denied.app: rejected",
                exitCode: 3
            )
        )

        #expect(details.gatekeeperStatus == .rejected)
        #expect(details.gatekeeperMessage == nil)
    }

    @Test("Parses real tool output from standard error")
    func standardErrorOutput() {
        let metadata = "CodeDirectory v=20500\nAuthority=Developer ID Application: Example Corp (ABCDE12345)\nTeamIdentifier=ABCDE12345"
        let verification = "/Applications/Example.app: valid on disk"
        let assessment = "/Applications/Example.app: accepted\nsource=Notarized Developer ID"
        let details = ApplicationSecurityParser.parse(
            applicationURL: URL(fileURLWithPath: "/Applications/Example.app"),
            signingMetadata: securityToolResult(
                output: metadata,
                success: true,
                standardOutput: "",
                standardError: metadata
            ),
            signingVerification: securityToolResult(
                output: verification,
                success: true,
                standardOutput: "",
                standardError: verification
            ),
            gatekeeperAssessment: securityToolResult(
                output: assessment,
                success: true,
                standardOutput: "",
                standardError: assessment
            )
        )

        #expect(details.signingStatus == .valid)
        #expect(details.signer == "Developer ID Application: Example Corp (ABCDE12345)")
        #expect(details.gatekeeperStatus == .accepted)
        #expect(details.notarizationStatus == .acceptedByGatekeeper)
    }

    @Test("Prefers the bundle verdict over codesign's stdout file list")
    func splitStreamSigningFailure() {
        let path = "/Applications/Broken.app"
        let standardOutput = """
        file modified: \(path)/Contents/Frameworks/Example.framework/Versions/Current/fileop
        file modified: \(path)/Contents/Frameworks/Example.framework/Versions/Current/Autoupdate
        """
        let standardError = """
        --prepared:\(path)/Contents/Frameworks/Example.framework
        --validated:\(path)/Contents/Frameworks/Example.framework
        \(path): a sealed resource is missing or invalid
        In subcomponent: \(path)/Contents/Frameworks/Example.framework
        """
        let details = ApplicationSecurityParser.parse(
            applicationURL: URL(fileURLWithPath: path),
            signingMetadata: securityToolResult(output: "", success: false),
            signingVerification: securityToolResult(
                output: standardOutput + "\n" + standardError,
                success: false,
                standardOutput: standardOutput,
                standardError: standardError,
                exitCode: 1
            ),
            gatekeeperAssessment: securityToolResult(
                output: "\(path): internal error in Code Signing subsystem",
                success: false,
                exitCode: 1
            )
        )

        #expect(details.signingStatus == .invalid)
        #expect(details.signingMessage == "A sealed resource is missing or invalid")
    }
}

@Suite("Application Security Inspection")
struct ApplicationSecurityInspectionTests {

    @Test("UI fixture supplies the signing details expected by the security view")
    func uiFixtureSecurityDetails() async {
        let inspector = ApplicationSecurityInspector(commandRunner: UITestCommandRunner())
        let details = await inspector.inspect(
            applicationURL: URL(fileURLWithPath: "/Applications/Firefox.app")
        )

        #expect(details.signingStatus == .valid)
        #expect(details.signer == "Developer ID Application: Mozilla Corporation (43AQ936H96)")
        #expect(details.teamIdentifier == "43AQ936H96")
        #expect(details.gatekeeperStatus == .accepted)
        #expect(details.gatekeeperSource == "Notarized Developer ID")
        #expect(details.notarizationStatus == .stapledTicket)
    }

    @Test("Runs bounded codesign and Gatekeeper checks with argument arrays")
    func runsExpectedCommands() async {
        let mock = MockCommandRunner()
        let path = "/Applications/Example.app"
        let metadataArguments = ["--display", "--verbose=4", "--", path]
        let verificationArguments = ["--verify", "--deep", "--strict", "--verbose=2", "--", path]
        let gatekeeperArguments = ["--assess", "--type", "execute", "--verbose=4", "--", path]
        mock.setResult(
            for: metadataArguments,
            output: "CodeDirectory v=20500\nAuthority=Developer ID Application: Example Corp (ABCDE12345)\nTeamIdentifier=ABCDE12345"
        )
        mock.setResult(for: verificationArguments, output: "valid on disk")
        mock.setResult(
            for: gatekeeperArguments,
            output: "source=Notarized Developer ID"
        )
        let inspector = ApplicationSecurityInspector(commandRunner: mock)

        let details = await inspector.inspect(
            applicationURL: URL(fileURLWithPath: path)
        )

        #expect(details.signingStatus == .valid)
        #expect(mock.executedExecutables.count == 3)
        #expect(mock.executedExecutables.contains { execution in
            execution.path == "/usr/bin/codesign" && execution.arguments == metadataArguments
        })
        #expect(mock.executedExecutables.contains { execution in
            execution.path == "/usr/bin/codesign" && execution.arguments == verificationArguments
        })
        #expect(mock.executedExecutables.contains { execution in
            execution.path == "/usr/sbin/spctl" && execution.arguments == gatekeeperArguments
        })
        #expect(mock.recordedTimeout(for: metadataArguments) == .seconds(30))
        #expect(mock.recordedTimeout(for: verificationArguments) == .seconds(30))
        #expect(mock.recordedTimeout(for: gatekeeperArguments) == .seconds(30))
    }
}

@Suite("BrewService Application Security")
@MainActor
struct BrewServiceApplicationSecurityTests {

    @Test("Does not run security tools when the application bundle is unknown")
    func unknownApplicationBundle() async {
        let mock = MockCommandRunner()
        let service = BrewService(commandRunner: mock)
        let package = makePackage(name: "example", source: .cask)

        let details = await service.applicationSecurityDetails(for: package)

        #expect(details == nil)
        #expect(mock.executedCommands.isEmpty)
    }
}

// codesign and spctl send their display/assessment diagnostics to stderr.
func securityToolResult(
    output: String,
    success: Bool,
    cancelled: Bool = false,
    timedOut: Bool = false,
    standardOutput: String? = nil,
    standardError: String? = nil,
    exitCode: Int32? = 1
) -> CommandResult {
    CommandResult(
        output: output, success: success, cancelled: cancelled, timedOut: timedOut,
        standardOutput: standardOutput ?? "", standardError: standardError ?? output,
        exitCode: success ? 0 : exitCode
    )
}
