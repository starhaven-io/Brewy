@testable import Brewy
import Foundation
import Testing

@Suite("GitHub repository URL parsing")
struct GitHubRepositoryURLTests {
    @Test("CaskJSON derives a canonical GitHub repository from its homepage")
    func caskRepositoryFromHomepage() throws {
        let package = try decodeCaskPackage(
            homepage: "https://www.github.com/example/example-app.git",
            url: "https://example.com/example.zip"
        )

        #expect(package.repositoryURL == "https://github.com/example/example-app")
    }

    @Test("CaskJSON derives a canonical GitHub repository from its download URL")
    func caskRepositoryFromDownloadURL() throws {
        let package = try decodeCaskPackage(
            homepage: "https://example.com",
            url: "https://github.com/example/example-app/releases/download/v1.0/example.zip"
        )

        #expect(package.repositoryURL == "https://github.com/example/example-app")
    }

    @Test("CaskJSON does not infer a repository from a lookalike GitHub host")
    func caskRepositoryRejectsLookalikeHost() throws {
        let package = try decodeCaskPackage(
            homepage: "https://github.com.example.invalid/example/example-app",
            url: "https://example.com/example.zip"
        )

        #expect(package.repositoryURL == nil)
    }

    @Test("CaskJSON ignores GitHub site routes and falls back to the download repository")
    func caskRepositoryRejectsGitHubSiteRoute() throws {
        let package = try decodeCaskPackage(
            homepage: "https://github.com/settings/profile",
            url: "https://github.com/example/example-app/releases/download/v1.0/example.zip"
        )

        #expect(package.repositoryURL == "https://github.com/example/example-app")
    }

    @Test("CaskJSON tolerates a non-string download URL")
    func caskRepositoryToleratesInvalidDownloadURLType() throws {
        let json = """
        {
            "formulae": [],
            "casks": [{"token": "example-app", "version": "1.0", "url": {"unexpected": true}}]
        }
        """
        let data = try #require(json.data(using: .utf8))
        let response = try JSONDecoder().decode(BrewInfoResponse.self, from: data)
        let cask = try #require(response.casks?.first)

        #expect(cask.toPackage().repositoryURL == nil)
    }

    private func decodeCaskPackage(homepage: String, url: String) throws -> BrewPackage {
        let json = """
        {
            "formulae": [],
            "casks": [
                {
                    "token": "example-app",
                    "version": "1.0",
                    "homepage": "\(homepage)",
                    "url": "\(url)"
                }
            ]
        }
        """
        let data = try #require(json.data(using: .utf8))
        let response = try JSONDecoder().decode(BrewInfoResponse.self, from: data)
        return try #require(response.casks?.first).toPackage()
    }
}

@Suite("GitHub repository package detail")
@MainActor
struct GitHubRepositoryPackageDetailTests {
    @Test("fetchPackageDetail preserves a repository when JSON omits it")
    func fetchDetailPreservesRepository() async {
        let mock = MockCommandRunner()
        let (service, _) = makeService(mock: mock)
        let package = makePackage(
            name: "firefox",
            source: .cask,
            repositoryURL: "https://github.com/mozilla/gecko-dev"
        )
        let detail = """
        {"formulae":[],"casks":[{"token":"firefox","version":"123.0",\
        "desc":"Fast web browser","homepage":"https://www.mozilla.org/firefox/"}]}
        """
        mock.setResult(for: ["info", "--cask", "--json=v2", "--", "firefox"], output: detail)

        let enriched = await service.fetchPackageDetail(for: package)

        #expect(enriched?.repositoryURL == "https://github.com/mozilla/gecko-dev")
    }

    @Test("fetchPackageDetail clears a repository when the download URL changes hosts")
    func fetchDetailClearsStaleRepository() async {
        let mock = MockCommandRunner()
        let (service, _) = makeService(mock: mock)
        let package = makePackage(
            name: "firefox",
            source: .cask,
            repositoryURL: "https://github.com/mozilla/gecko-dev"
        )
        let detail = """
        {"formulae":[],"casks":[{"token":"firefox","version":"123.0",\
        "homepage":"https://www.mozilla.org/firefox/","url":"https://download.mozilla.org/firefox.dmg"}]}
        """
        mock.setResult(for: ["info", "--cask", "--json=v2", "--", "firefox"], output: detail)

        let enriched = await service.fetchPackageDetail(for: package)

        #expect(enriched?.repositoryURL == nil)
    }
}
