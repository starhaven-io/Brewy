@testable import Brewy
import Foundation
import SwiftUI
import Testing

@Suite("ExternalURLPolicy")
struct ExternalURLPolicyTests {

    @Test("Allows HTTP and HTTPS URLs with hosts")
    func allowsWebURLs() {
        #expect(ExternalURLPolicy.url(from: "https://example.com/path")?.host == "example.com")
        #expect(ExternalURLPolicy.url(from: "http://example.com/path")?.scheme == "http")
    }

    @Test("Rejects local custom and malformed URLs")
    func rejectsUnsafeURLs() {
        #expect(ExternalURLPolicy.url(from: "file:///etc/passwd") == nil)
        #expect(ExternalURLPolicy.url(from: "javascript:alert(1)") == nil)
        #expect(ExternalURLPolicy.url(from: "data:text/plain,hello") == nil)
        #expect(ExternalURLPolicy.url(from: "https:///missing-host") == nil)
    }
}

@Suite("ReleaseNotesHTML")
struct ReleaseNotesHTMLTests {

    @Test("Removes unsafe link attributes")
    func removesUnsafeLinks() throws {
        let html = #"""
        <p>
          <a href="javascript:alert(1)">bad</a>
          <a href="file:///tmp/bad">file</a>
          <a href="https://example.com/release">good</a>
        </p>
        """#

        let attributed = try #require(ReleaseNotesHTML.attributedString(from: html))
        let links = attributed.runs.compactMap(\.link)

        #expect(links == [URL(string: "https://example.com/release")])
    }

    @Test("Strips external resource tags")
    func stripsExternalResourceTags() throws {
        let html = #"<p>Before</p><img src="https://example.com/tracker.png"><p>After</p>"#
        let attributed = try #require(ReleaseNotesHTML.attributedString(from: html))

        #expect(String(attributed.characters).contains("Before"))
        #expect(String(attributed.characters).contains("After"))
        #expect(String(attributed.characters).contains("\u{fffc}") == false)
    }

    @Test("Strips resource tags that re-form after a single pass")
    func stripsReformingResourceTags() {
        // A naive single pass turns this into a live "<img src=...>" that would
        // trigger a network load; the fixed-point strip must remove it entirely.
        let payload = #"<<img>img src="https://evil.example/beacon.png">"#
        let stripped = ReleaseNotesHTML.stripUnsafeMarkup(from: payload)

        #expect(stripped.range(of: "<img", options: .caseInsensitive) == nil)
        #expect(stripped.range(of: "src=", options: .caseInsensitive) == nil)
    }
}

@Suite("BrewService Safety Guardrails")
@MainActor
struct BrewServiceSafetyGuardrailTests {

    @Test("search inserts option separator before query")
    func searchUsesOptionSeparator() async {
        let mock = MockCommandRunner()
        let (service, _) = makeService(mock: mock)
        mock.setResult(for: ["search", "--formula", "--", "--eval-all"], output: "safe-result")
        mock.setResult(for: ["search", "--cask", "--", "--eval-all"], output: "")

        await service.search(query: "--eval-all")

        #expect(mock.executedCommands.contains(["search", "--formula", "--", "--eval-all"]))
        #expect(mock.executedCommands.contains(["search", "--cask", "--", "--eval-all"]))
    }

    @Test("upgradeSelected excludes mas apps and reports App Store updates")
    func upgradeSelectedReportsMasApps() async {
        let mock = MockCommandRunner()
        let (service, _) = makeService(mock: mock)
        setupRefreshMock(mock)

        let formula = makePackage(name: "wget", source: .formula)
        let masApp = makePackage(name: "Xcode", source: .mas)
        mock.setResult(for: ["upgrade", "wget"], output: "Upgraded wget")

        await service.upgradeSelected(packages: [formula, masApp])

        #expect(mock.executedCommands.contains(["upgrade", "wget"]))
        #expect(!mock.executedCommands.contains { $0.contains("Xcode") })
        #expect(service.lastError?.localizedDescription.contains("Mac App Store") == true)
    }

    @Test("upgradeAll reports outdated mas apps separately")
    func upgradeAllReportsMasApps() async {
        let mock = MockCommandRunner()
        let (service, _) = makeService(mock: mock)
        setupRefreshMock(mock)
        service.outdatedPackages = [makePackage(name: "Xcode", source: .mas, isOutdated: true)]
        mock.setResult(for: ["upgrade"], output: "All upgraded")

        await service.upgradeAll()

        #expect(mock.executedCommands.contains(["upgrade"]))
        #expect(service.lastError?.localizedDescription.contains("Mac App Store") == true)
    }
}
