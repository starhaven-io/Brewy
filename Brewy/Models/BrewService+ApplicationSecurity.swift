import Foundation

struct ApplicationSecurityInspector: Sendable {
    private static let inspectionTimeout: Duration = .seconds(30)
    private let commandRunner: CommandRunning

    init(commandRunner: CommandRunning) {
        self.commandRunner = commandRunner
    }

    func inspect(applicationURL: URL) async -> ApplicationSecurityDetails {
        let applicationURL = applicationURL.standardizedFileURL
        let path = applicationURL.path
        let metadataArguments = ["--display", "--verbose=4", "--", path]
        let verificationArguments = ["--verify", "--deep", "--strict", "--verbose=2", "--", path]
        let gatekeeperArguments = ["--assess", "--type", "execute", "--verbose=4", "--", path]

        async let signingMetadata = commandRunner.runExecutable(
            "/usr/bin/codesign",
            arguments: metadataArguments,
            timeout: Self.inspectionTimeout
        )
        async let signingVerification = commandRunner.runExecutable(
            "/usr/bin/codesign",
            arguments: verificationArguments,
            timeout: Self.inspectionTimeout
        )
        async let gatekeeperAssessment = commandRunner.runExecutable(
            "/usr/sbin/spctl",
            arguments: gatekeeperArguments,
            timeout: Self.inspectionTimeout
        )

        return await ApplicationSecurityParser.parse(
            applicationURL: applicationURL,
            signingMetadata: signingMetadata,
            signingVerification: signingVerification,
            gatekeeperAssessment: gatekeeperAssessment
        )
    }
}

extension BrewService {
    func applicationSecurityDetails(for package: BrewPackage) async -> ApplicationSecurityDetails? {
        guard package.isInstalled,
              !package.isFormula,
              let applicationURL = installedApplicationURL(for: package) else {
            return nil
        }
        return await ApplicationSecurityInspector(commandRunner: commandRunner)
            .inspect(applicationURL: applicationURL)
    }
}
