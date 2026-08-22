import AppKit
@testable import Brewy
import Foundation
import Testing

@Suite("Cask Application Artifacts")
struct CaskApplicationArtifactTests {

    @Test("CaskJSON exposes application artifact targets")
    func applicationArtifactTargets() throws {
        let json = """
        {
            "formulae": [],
            "casks": [
                {
                    "token": "firefox",
                    "version": "122.0",
                    "artifacts": [
                        { "uninstall": [{ "quit": "org.mozilla.firefox" }] },
                        {
                            "app": ["Firefox Source.app", { "target": "Firefox.app" }],
                            "target": "/Applications/Firefox.app"
                        },
                        { "binary": ["firefox"], "target": "/opt/homebrew/bin/firefox" }
                    ]
                }
            ]
        }
        """
        let data = try #require(json.data(using: .utf8))
        let response = try JSONDecoder().decode(BrewInfoResponse.self, from: data)
        let cask = try #require(response.casks?.first)

        #expect(cask.applicationBundleURLs.map(\.path) == ["/Applications/Firefox.app"])
    }

    @Test("Unexpected artifact shapes do not discard installed packages")
    func unexpectedArtifactShapesAreIgnored() throws {
        let json = """
        {
            "formulae": [{ "name": "wget", "installed": [{ "version": "1.0" }] }],
            "casks": [
                {
                    "token": "firefox",
                    "version": "122.0",
                    "artifacts": [["Firefox.app"]]
                },
                {
                    "token": "broken-artifacts",
                    "version": "1.0",
                    "artifacts": { "app": ["Broken.app"] }
                },
                {
                    "token": "mixed-targets",
                    "version": "1.0",
                    "artifacts": [
                        { "app": ["Broken.app"], "target": { "path": "/Applications/Broken.app" } },
                        { "app": ["Working.app"], "target": "/Applications/Working.app" }
                    ]
                }
            ]
        }
        """
        let data = try #require(json.data(using: .utf8))
        let response = try JSONDecoder().decode(BrewInfoResponse.self, from: data)

        #expect(response.formulae?.count == 1)
        #expect(response.casks?.count == 3)
        #expect(response.casks?.first?.applicationBundleURLs.isEmpty == true)
        #expect(response.casks?[1].applicationBundleURLs.isEmpty == true)
        #expect(response.casks?[2].applicationBundleURLs.map(\.path) == ["/Applications/Working.app"])
    }
}

@Suite("Installed Application URL Refreshing")
struct InstalledApplicationURLRefreshTests {

    @Test("A successful brew refresh preserves MAS URLs when MAS fails")
    func brewSuccessPreservesMasFailure() {
        let urls = BrewService.refreshedApplicationURLs(
            existingURLs: [
                "cask-firefox": URL(fileURLWithPath: "/Applications/Old Firefox.app"),
                "mas-497799835": URL(fileURLWithPath: "/Applications/Xcode.app"),
                "cask-removed": URL(fileURLWithPath: "/Applications/Removed.app")
            ],
            brewURLs: ["cask-firefox": URL(fileURLWithPath: "/Applications/Firefox.app")],
            masURLs: nil,
            installedIDs: ["cask-firefox", "mas-497799835"]
        )

        #expect(urls["cask-firefox"]?.path == "/Applications/Firefox.app")
        #expect(urls["mas-497799835"]?.path == "/Applications/Xcode.app")
        #expect(urls["cask-removed"] == nil)
    }

    @Test("A successful MAS refresh preserves cask URLs when brew fails")
    func masSuccessPreservesBrewFailure() {
        let urls = BrewService.refreshedApplicationURLs(
            existingURLs: [
                "cask-firefox": URL(fileURLWithPath: "/Applications/Firefox.app"),
                "mas-497799835": URL(fileURLWithPath: "/Applications/Old Xcode.app")
            ],
            brewURLs: nil,
            masURLs: ["mas-497799835": URL(fileURLWithPath: "/Applications/Xcode.app")],
            installedIDs: ["cask-firefox", "mas-497799835"]
        )

        #expect(urls["cask-firefox"]?.path == "/Applications/Firefox.app")
        #expect(urls["mas-497799835"]?.path == "/Applications/Xcode.app")
    }
}

@Suite("Installed Application Icons")
@MainActor
struct InstalledApplicationIconTests {

    @Test("Icon cache reuses a loaded application icon")
    func cacheReusesLoadedIcon() async throws {
        let url = URL(fileURLWithPath: "/Applications/Test.app")
        let probe = IconLoadProbe(fileExists: true)
        let cache = InstalledApplicationIconCache(
            fileExists: probe.checkFileExists,
            iconProvider: probe.loadIcon
        )

        let first = try #require(await cache.image(for: url, version: "1.0"))
        let second = try #require(await cache.image(for: url, version: "1.0"))

        #expect(first === probe.image)
        #expect(second === probe.image)
        #expect(probe.existenceCheckCount == 1)
        #expect(probe.loadCount == 1)
    }

    @Test("Icon cache rejects missing and non-application paths")
    func cacheRejectsInvalidPaths() async {
        let probe = IconLoadProbe(fileExists: false)
        let cache = InstalledApplicationIconCache(
            fileExists: probe.checkFileExists,
            iconProvider: probe.loadIcon
        )

        let missing = await cache.image(for: URL(fileURLWithPath: "/Applications/Missing.app"), version: "1.0")
        let nonApplication = await cache.image(for: URL(fileURLWithPath: "/tmp/not-an-app"), version: "1.0")

        #expect(missing == nil)
        #expect(nonApplication == nil)
        #expect(probe.loadCount == 0)
    }

    @Test("Cold icon loading does not run on the main thread")
    func coldLoadRunsOffMainThread() async throws {
        let probe = IconLoadProbe(fileExists: true)
        let cache = InstalledApplicationIconCache(
            fileExists: probe.checkFileExists,
            iconProvider: probe.loadIcon
        )

        _ = try #require(await cache.image(
            for: URL(fileURLWithPath: "/Applications/Test.app"),
            version: "1.0"
        ))

        #expect(probe.loadedOnMainThread == false)
    }

    @Test("A new package version reloads an icon at the same path")
    func versionChangeReloadsIcon() async throws {
        let url = URL(fileURLWithPath: "/Applications/Test.app")
        let probe = IconLoadProbe(fileExists: true)
        let cache = InstalledApplicationIconCache(
            fileExists: probe.checkFileExists,
            iconProvider: probe.loadIcon
        )

        _ = try #require(await cache.image(for: url, version: "1.0"))
        _ = try #require(await cache.image(for: url, version: "1.0"))
        #expect(probe.loadCount == 1)

        _ = try #require(await cache.image(for: url, version: "2.0"))
        #expect(probe.loadCount == 2)
    }
}

private final class IconLoadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let fileExists: Bool
    let image = NSImage(size: NSSize(width: 16, height: 16))
    private var _existenceCheckCount = 0
    private var _loadCount = 0
    private var _loadedOnMainThread: Bool?

    init(fileExists: Bool) {
        self.fileExists = fileExists
    }

    var existenceCheckCount: Int {
        lock.withLock { _existenceCheckCount }
    }

    var loadCount: Int {
        lock.withLock { _loadCount }
    }

    var loadedOnMainThread: Bool? {
        lock.withLock { _loadedOnMainThread }
    }

    func checkFileExists(_: String) -> Bool {
        lock.withLock {
            _existenceCheckCount += 1
            return fileExists
        }
    }

    func loadIcon(_: String) -> NSImage {
        lock.withLock {
            _loadCount += 1
            _loadedOnMainThread = Thread.isMainThread
            return image
        }
    }
}
