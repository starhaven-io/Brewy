import Foundation

enum BrewyRuntime {
    static var isUITesting: Bool {
#if DEBUG
        ProcessInfo.processInfo.environment["BREWY_UI_TESTING"] == "1"
#else
        false
#endif
    }

    static var isUnitTesting: Bool {
#if DEBUG
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestBundlePath"] != nil
            || environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
#else
        false
#endif
    }

    static var isRunningTests: Bool {
        isUITesting || isUnitTesting
    }
}

#if DEBUG
struct UITestCommandRunner: CommandRunning {
    func run(_ arguments: [String], brewPath: String, timeout: Duration) async -> CommandResult {
        if arguments == ["services", "info", "--all", "--json"] {
            return CommandResult(output: Self.servicesJSON, success: true)
        }
        if arguments.first == "info" {
            return CommandResult(
                output: "From: https://github.com/Homebrew/homebrew-core\nLicense: Unlicense\n",
                success: true
            )
        }
        if arguments == ["--cache"] {
            return CommandResult(output: "/private/tmp/brewy-ui-cache\n", success: true)
        }
        if arguments == ["config"] {
            return CommandResult(output: Self.configOutput, success: true)
        }
        if arguments == ["cleanup", "--prune=all", "-s", "--dry-run"] {
            if ProcessInfo.processInfo.environment["BREWY_UI_CLEANUP_PREVIEW_FAILURE"] == "1" {
                return CommandResult(output: "Fixture cleanup preview failed", success: false)
            }
            return CommandResult(output: "Fixture cleanup preview", success: true)
        }
        if arguments.starts(with: ["bundle", "list"]) {
            return Self.bundleListResult(arguments)
        }
        if arguments.starts(with: ["bundle", "check"]) {
            return CommandResult(output: "jq needs to be installed or updated.\n", success: false)
        }
        return CommandResult(output: "Fixture command completed.\n", success: true)
    }

    func runExecutable(
        _ executablePath: String,
        arguments: [String],
        timeout: Duration
    ) async -> CommandResult {
        if executablePath == "/usr/bin/du" {
            return CommandResult(output: "2048\t/private/tmp/brewy-ui-cache\n", success: true)
        }
        return CommandResult(output: "Fixture command completed.\n", success: true)
    }

    private static func bundleListResult(_ arguments: [String]) -> CommandResult {
        let output: String
        if arguments.contains("--formula") {
            output = "ripgrep\njq\n"
        } else if arguments.contains("--cask") {
            output = "firefox\n"
        } else if arguments.contains("--tap") {
            output = "starhaven-io/tap\n"
        } else if arguments.contains("--mas") {
            output = "Xcode\n"
        } else {
            output = ""
        }
        return CommandResult(output: output, success: true)
    }

    private static let servicesJSON = """
    [
      {
        "name": "postgresql@17",
        "service_name": "homebrew.mxcl.postgresql@17",
        "running": true,
        "loaded": true,
        "pid": 4242,
        "exit_code": 0,
        "user": "patrick",
        "status": "started",
        "file": "/opt/homebrew/opt/postgresql@17/homebrew.mxcl.postgresql@17.plist",
        "log_path": "/opt/homebrew/var/log/postgresql@17.log",
        "error_log_path": "/opt/homebrew/var/log/postgresql@17.error.log"
      },
      {
        "name": "redis",
        "service_name": "homebrew.mxcl.redis",
        "running": false,
        "loaded": false,
        "pid": null,
        "exit_code": null,
        "user": null,
        "status": "stopped",
        "file": "/opt/homebrew/opt/redis/homebrew.mxcl.redis.plist",
        "log_path": null,
        "error_log_path": null
      }
    ]
    """

    private static let configOutput = """
    HOMEBREW_VERSION: 4.6.0
    Last commit: 2 days ago
    Core tap last commit: 3 days ago
    Core cask tap last commit: 4 days ago
    """
}

extension BrewService {
    func loadUITestFixtures() {
        let fixtureTimestamp = Date().addingTimeInterval(-3_600)
        let packages = loadUITestPackages()
        loadUITestMetadata(
            fixtureTimestamp: fixtureTimestamp,
            ripgrep: packages.ripgrep,
            pcre2: packages.pcre2,
            firefox: packages.firefox
        )
        loadUITestBundle()
    }

    private func loadUITestPackages() -> (ripgrep: BrewPackage, pcre2: BrewPackage, firefox: BrewPackage) {
        let ripgrep = makeRipgrepFixture()
        let pcre2 = makePcre2Fixture()
        let firefox = makeFirefoxFixture()
        let xcode = makeXcodeFixture()

        installedFormulae = [ripgrep, pcre2]
        installedCasks = [firefox]
        installedMasApps = [xcode]
        isMasAvailable = true
        outdatedPackages = [ripgrep, firefox]

        return (ripgrep, pcre2, firefox)
    }

    private func makeRipgrepFixture() -> BrewPackage {
        BrewPackage(
            id: "formula-ripgrep",
            name: "ripgrep",
            version: "14.1.0",
            description: "Search tool like grep and The Silver Searcher",
            homepage: "https://github.com/BurntSushi/ripgrep",
            isInstalled: true,
            isOutdated: true,
            installedVersion: "14.1.0",
            latestVersion: "14.1.1",
            source: .formula,
            pinned: true,
            installedOnRequest: true,
            dependencies: ["pcre2"]
        )
    }

    private func makePcre2Fixture() -> BrewPackage {
        BrewPackage(
            id: "formula-pcre2",
            name: "pcre2",
            version: "10.45",
            description: "Perl compatible regular expressions library",
            homepage: "https://www.pcre.org/",
            isInstalled: true,
            isOutdated: false,
            installedVersion: "10.45",
            latestVersion: nil,
            source: .formula,
            pinned: false,
            installedOnRequest: false,
            dependencies: []
        )
    }

    private func makeFirefoxFixture() -> BrewPackage {
        BrewPackage(
            id: "cask-firefox",
            name: "firefox",
            version: "127.0",
            description: "Web browser",
            homepage: "https://www.mozilla.org/firefox/",
            isInstalled: true,
            isOutdated: true,
            installedVersion: "127.0",
            latestVersion: "128.0",
            source: .cask,
            pinned: false,
            installedOnRequest: true,
            dependencies: []
        )
    }

    private func makeXcodeFixture() -> BrewPackage {
        BrewPackage(
            id: "mas-497799835",
            name: "Xcode",
            version: "26.0",
            description: "Developer tools from Apple",
            homepage: "https://apps.apple.com/app/xcode/id497799835",
            isInstalled: true,
            isOutdated: false,
            installedVersion: "26.0",
            latestVersion: nil,
            source: .mas,
            pinned: false,
            installedOnRequest: true,
            dependencies: []
        )
    }

    private func loadUITestMetadata(
        fixtureTimestamp: Date,
        ripgrep: BrewPackage,
        pcre2: BrewPackage,
        firefox: BrewPackage
    ) {
        installedTaps = [
            BrewTap(
                name: "starhaven-io/tap",
                remote: "https://github.com/starhaven-io/homebrew-tap",
                isOfficial: false,
                formulaNames: ["ripgrep"],
                caskTokens: ["firefox"]
            )
        ]
        tapHealthStatuses = [
            "starhaven-io/tap": TapHealthStatus(
                status: .archived,
                movedTo: nil,
                lastChecked: fixtureTimestamp
            )
        ]
        packageGroups = [
            PackageGroup(
                id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                name: "Development",
                systemImage: "hammer.fill",
                packageIDs: [ripgrep.id, pcre2.id]
            ),
            PackageGroup(
                id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                name: "Browsers",
                systemImage: "globe",
                packageIDs: [firefox.id]
            )
        ]
        actionHistory = [
            ActionHistoryEntry(
                id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
                command: "upgrade",
                arguments: ["upgrade", "ripgrep"],
                packageName: "ripgrep",
                packageSource: .formula,
                status: .failure,
                output: "Error: fixture upgrade failed",
                timestamp: fixtureTimestamp
            )
        ]
        lastUpdateResult = BrewUpdateResult(
            newFormulae: [
                BrewUpdateItem(name: "atuin", description: "Shell history sync", source: .formula)
            ],
            newCasks: [
                BrewUpdateItem(name: "zed", description: "High-performance editor", source: .cask)
            ],
            timestamp: fixtureTimestamp
        )
        lastUpdated = fixtureTimestamp
    }

    private func loadUITestBundle() {
        brewfileURL = resolveBrewfile()
        bundleEntries = [
            BrewBundleEntry(type: .formula, name: "ripgrep", status: .installed),
            BrewBundleEntry(type: .formula, name: "jq", status: .missing),
            BrewBundleEntry(type: .cask, name: "firefox", status: .installed),
            BrewBundleEntry(type: .tap, name: "starhaven-io/tap", status: .installed),
            BrewBundleEntry(type: .mas, name: "Xcode", status: .installed)
        ]
        bundleCheckStatus = .unsatisfied(["jq"])
    }
}
#endif
