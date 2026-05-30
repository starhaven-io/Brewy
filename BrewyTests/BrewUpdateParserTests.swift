@testable import Brewy
import Foundation
import Testing

// MARK: - BrewUpdateParser Tests

@Suite("BrewUpdateParser")
struct BrewUpdateParserTests {

    @Test("Parses a typical brew update output with new formulae and casks")
    func parsesTypicalOutput() {
        let output = """
        Updated Homebrew from abc123 to def456.
        Updated 2 taps (homebrew/core, homebrew/cask).
        ==> New Formulae
        copilot-language-server: Language Server Protocol server for GitHub Copilot
        graalvm: JDK distribution with Graal compiler and Native Image
        ==> New Casks
        claude-code@latest: Terminal-based AI coding assistant
        font-ioskeley-mono
        wallspace: Live wallpaper app
        """
        let result = BrewUpdateParser.parse(output)

        #expect(result.newFormulae.count == 2)
        #expect(result.newFormulae[0].name == "copilot-language-server")
        #expect(result.newFormulae[0].description == "Language Server Protocol server for GitHub Copilot")
        #expect(result.newFormulae[0].source == .formula)
        #expect(result.newFormulae[1].name == "graalvm")

        #expect(result.newCasks.count == 3)
        #expect(result.newCasks[0].name == "claude-code@latest")
        #expect(result.newCasks[0].description == "Terminal-based AI coding assistant")
        #expect(result.newCasks[0].source == .cask)
    }

    @Test("Handles items without a description")
    func itemWithoutDescription() {
        let output = """
        ==> New Casks
        font-ioskeley-mono
        """
        let result = BrewUpdateParser.parse(output)

        #expect(result.newCasks.count == 1)
        #expect(result.newCasks[0].name == "font-ioskeley-mono")
        #expect(result.newCasks[0].description == nil)
    }

    @Test("Preserves colons inside descriptions")
    func descriptionWithColon() {
        let output = """
        ==> New Formulae
        rvvm: RISC-V Virtual Machine: x86 host edition
        """
        let result = BrewUpdateParser.parse(output)

        #expect(result.newFormulae.count == 1)
        #expect(result.newFormulae[0].name == "rvvm")
        #expect(result.newFormulae[0].description == "RISC-V Virtual Machine: x86 host edition")
    }

    @Test("Empty output yields empty result")
    func emptyOutput() {
        let result = BrewUpdateParser.parse("")
        #expect(result.newFormulae.isEmpty)
        #expect(result.newCasks.isEmpty)
        #expect(result.isEmpty)
        #expect(result.totalCount == 0)
    }

    @Test("Already up-to-date output yields empty result")
    func alreadyUpToDate() {
        let output = """
        Already up-to-date.
        """
        let result = BrewUpdateParser.parse(output)
        #expect(result.isEmpty)
    }

    @Test("Ignores sections that are not New Formulae or New Casks")
    func skipsNonTargetSections() {
        let output = """
        ==> Outdated Formulae
        wget
        curl
        ==> New Formulae
        a-new-thing: A new thing
        ==> Updated Casks
        firefox
        ==> New Casks
        another-thing: Another thing
        """
        let result = BrewUpdateParser.parse(output)

        #expect(result.newFormulae.count == 1)
        #expect(result.newFormulae[0].name == "a-new-thing")
        #expect(result.newCasks.count == 1)
        #expect(result.newCasks[0].name == "another-thing")
    }

    @Test("Skips blank lines inside sections")
    func skipsBlankLines() {
        let output = """
        ==> New Formulae

        foo: foo desc

        bar: bar desc
        """
        let result = BrewUpdateParser.parse(output)

        #expect(result.newFormulae.count == 2)
        #expect(result.newFormulae[0].name == "foo")
        #expect(result.newFormulae[1].name == "bar")
    }

    @Test("Ignores lines before the first section header")
    func ignoresPreHeaderLines() {
        let output = """
        Updating Homebrew...
        Updated 1 tap.
        ==> New Formulae
        thing: Cool thing
        """
        let result = BrewUpdateParser.parse(output)
        #expect(result.newFormulae.count == 1)
    }

    @Test("Header is case-insensitive")
    func headerCaseInsensitive() {
        let output = """
        ==> NEW FORMULAE
        foo: Foo
        ==> new casks
        bar: Bar
        """
        let result = BrewUpdateParser.parse(output)
        #expect(result.newFormulae.count == 1)
        #expect(result.newCasks.count == 1)
    }

    @Test("totalCount reflects the sum of new formulae and casks")
    func totalCount() {
        let output = """
        ==> New Formulae
        a: A
        b: B
        c: C
        ==> New Casks
        d: D
        """
        let result = BrewUpdateParser.parse(output)
        #expect(result.totalCount == 4)
        #expect(!result.isEmpty)
    }

    @Test("asPlaceholderPackage produces a BrewPackage matching the item")
    func asPlaceholderPackageMatchesItem() {
        let formulaItem = BrewUpdateItem(name: "wget", description: "File retriever", source: .formula)
        let pkg = formulaItem.asPlaceholderPackage()
        #expect(pkg.name == "wget")
        #expect(pkg.source == .formula)
        #expect(pkg.description == "File retriever")
        #expect(!pkg.isInstalled)
        #expect(!pkg.isOutdated)
        #expect(pkg.id == formulaItem.id)

        let caskWithoutDesc = BrewUpdateItem(name: "font-foo", description: nil, source: .cask)
        let caskPkg = caskWithoutDesc.asPlaceholderPackage()
        #expect(caskPkg.source == .cask)
        #expect(caskPkg.description.isEmpty)
    }

    @Test("Codable round-trip preserves all fields")
    func codableRoundTrip() throws {
        let original = BrewUpdateResult(
            newFormulae: [BrewUpdateItem(name: "foo", description: "Foo lib", source: .formula)],
            newCasks: [BrewUpdateItem(name: "bar", description: nil, source: .cask)],
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(BrewUpdateResult.self, from: data)
        #expect(decoded.newFormulae.count == 1)
        #expect(decoded.newFormulae[0].name == "foo")
        #expect(decoded.newCasks.count == 1)
        #expect(decoded.newCasks[0].description == nil)
        #expect(decoded.timestamp == original.timestamp)
    }
}
