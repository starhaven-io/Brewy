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
@MainActor
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

    @Test("Deeply reforming markup is neutralized in one pass")
    func deeplyReformingMarkupIsNeutralized() {
        let payload = String(repeating: "<", count: 20) + String(repeating: "img>", count: 20)
        let stripped = ReleaseNotesHTML.stripUnsafeMarkup(from: payload)

        #expect(stripped.range(of: "<img", options: .caseInsensitive) == nil)
    }

    @Test("Oversized markup is rejected before HTML conversion")
    func oversizedMarkupIsRejected() {
        let payload = String(repeating: "a", count: ReleaseNotesHTML.maximumHTMLByteCount + 1)
        #expect(ReleaseNotesHTML.attributedString(from: payload) == nil)
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

    @Test("package actions insert option separator before package name")
    func packageActionsUseOptionSeparator() async {
        let mock = MockCommandRunner()
        let (service, _) = makeService(mock: mock)
        setupRefreshMock(mock)

        let formula = makePackage(name: "--eval-all", source: .formula)
        let cask = makePackage(name: "--zap", source: .cask)
        let formulaCommand = ["install", "--", "--eval-all"]
        let caskCommand = ["install", "--cask", "--", "--zap"]
        mock.setResult(for: formulaCommand, output: "Installed formula")
        mock.setResult(for: caskCommand, output: "Installed cask")

        await service.install(package: formula)
        await service.install(package: cask)

        #expect(mock.executedCommands.contains(formulaCommand))
        #expect(mock.executedCommands.contains(caskCommand))
    }

    @Test("read-only package info commands insert option separator before package name")
    func packageInfoUsesOptionSeparator() async {
        let mock = MockCommandRunner()
        let (service, _) = makeService(mock: mock)

        let formula = makePackage(name: "--eval-all", source: .formula)
        let cask = makePackage(name: "--zap", source: .cask)
        let formulaInfoCommand = ["info", "--", "--eval-all"]
        let caskInfoCommand = ["info", "--cask", "--", "--zap"]
        let formulaDetailCommand = ["info", "--json=v2", "--", "--eval-all"]
        let caskDetailCommand = ["info", "--cask", "--json=v2", "--", "--zap"]
        mock.setResult(for: formulaInfoCommand, output: "formula info")
        mock.setResult(for: caskInfoCommand, output: "cask info")
        mock.setResult(for: formulaDetailCommand, output: TestJSON.formulaDetail)
        mock.setResult(for: caskDetailCommand, output: TestJSON.caskDetail)

        _ = await service.info(for: formula)
        _ = await service.info(for: cask)
        _ = await service.fetchPackageDetail(for: formula)
        _ = await service.fetchPackageDetail(for: cask)

        #expect(mock.executedCommands.contains(formulaInfoCommand))
        #expect(mock.executedCommands.contains(caskInfoCommand))
        #expect(mock.executedCommands.contains(formulaDetailCommand))
        #expect(mock.executedCommands.contains(caskDetailCommand))
    }

    @Test("upgradeSelected inserts option separator before package names")
    func upgradeSelectedUsesOptionSeparator() async {
        let mock = MockCommandRunner()
        let (service, _) = makeService(mock: mock)
        setupRefreshMock(mock)

        let formula = makePackage(name: "--eval-all", source: .formula)
        let cask = makePackage(name: "--zap", source: .cask)
        let formulaCommand = ["upgrade", "--", "--eval-all"]
        let caskCommand = ["upgrade", "--cask", "--", "--zap"]
        mock.setResult(for: formulaCommand, output: "Upgraded formula")
        mock.setResult(for: caskCommand, output: "Upgraded cask")

        await service.upgradeSelected(packages: [formula, cask])

        #expect(mock.executedCommands.contains(formulaCommand))
        #expect(mock.executedCommands.contains(caskCommand))
    }

    @Test("upgradeSelected excludes mas apps and reports App Store updates")
    func upgradeSelectedReportsMasApps() async {
        let mock = MockCommandRunner()
        let (service, _) = makeService(mock: mock)
        setupRefreshMock(mock)

        let formula = makePackage(name: "wget", source: .formula)
        let masApp = makePackage(name: "Xcode", source: .mas)
        mock.setResult(for: ["upgrade", "--", "wget"], output: "Upgraded wget")

        await service.upgradeSelected(packages: [formula, masApp])

        #expect(mock.executedCommands.contains(["upgrade", "--", "wget"]))
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
