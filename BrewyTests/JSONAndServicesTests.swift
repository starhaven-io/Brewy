@testable import Brewy
import Foundation
import Testing

// MARK: - JSON Parsing Edge Cases

@Suite("JSON Parsing Edge Cases")
struct JSONParsingEdgeCaseTests {

    @Test("Malformed JSON returns nil")
    func malformedJSON() {
        let data = Data("not json at all".utf8)
        let response = try? JSONDecoder().decode(BrewInfoResponse.self, from: data)
        #expect(response == nil)
    }

    @Test("Empty formulae and casks arrays parse correctly")
    func emptyArrays() throws {
        let json = "{\"formulae\":[],\"casks\":[]}"
        let data = try #require(json.data(using: .utf8))
        let response = try JSONDecoder().decode(BrewInfoResponse.self, from: data)
        #expect(response.formulae?.isEmpty == true)
        #expect(response.casks?.isEmpty == true)
    }

    @Test("Extra unknown fields in JSON are ignored")
    func extraFields() throws {
        let json = """
        {"formulae":[{"name":"wget","desc":"test","homepage":"",\
        "versions":{"stable":"1.0"},"pinned":false,\
        "installed":[{"version":"1.0","installed_on_request":true}],\
        "dependencies":[],"extra_field":"ignored","another":42}],"casks":[]}
        """
        let data = try #require(json.data(using: .utf8))
        let response = try JSONDecoder().decode(BrewInfoResponse.self, from: data)
        let formulae = try #require(response.formulae)
        #expect(formulae.count == 1)
        #expect(formulae[0].name == "wget")
    }

    @Test("Unicode characters in package descriptions")
    func unicodeDescriptions() throws {
        let json = """
        {"formulae":[{"name":"test","desc":"Japanese test description",\
        "homepage":"","versions":{"stable":"1.0"},"pinned":false,\
        "installed":[{"version":"1.0","installed_on_request":true}],\
        "dependencies":[]}],"casks":[]}
        """
        let data = try #require(json.data(using: .utf8))
        let response = try JSONDecoder().decode(BrewInfoResponse.self, from: data)
        let formulae = try #require(response.formulae)
        let pkg = formulae[0].toPackage()
        #expect(pkg.description.contains("Japanese"))
    }

    @Test("OutdatedResponse with empty formulae and casks")
    func emptyOutdatedResponse() throws {
        let json = "{\"formulae\":[],\"casks\":[]}"
        let data = try #require(json.data(using: .utf8))
        let response = try JSONDecoder().decode(BrewOutdatedResponse.self, from: data)
        #expect(response.formulae?.isEmpty == true)
        #expect(response.casks?.isEmpty == true)
    }

    @Test("Multiple formulae parse correctly")
    func multipleFormulae() throws {
        let json = """
        {"formulae":[
        {"name":"wget","desc":"","homepage":"","versions":{"stable":"1.0"},\
        "pinned":false,"installed":[{"version":"1.0","installed_on_request":true}],"dependencies":[]},
        {"name":"curl","desc":"","homepage":"","versions":{"stable":"8.0"},\
        "pinned":true,"installed":[{"version":"8.0","installed_on_request":false}],"dependencies":["openssl"]}
        ],"casks":[]}
        """
        let data = try #require(json.data(using: .utf8))
        let response = try JSONDecoder().decode(BrewInfoResponse.self, from: data)
        let formulae = try #require(response.formulae)
        #expect(formulae.count == 2)
        #expect(formulae[1].name == "curl")
        #expect(formulae[1].pinned == true)

        let pkg = formulae[1].toPackage()
        #expect(pkg.pinned == true)
        #expect(pkg.installedOnRequest == false)
        #expect(pkg.dependencies == ["openssl"])
    }

    @Test("Formula JSON uses newest installed keg")
    func formulaUsesNewestInstalledKeg() throws {
        let json = """
        {"formulae":[{"name":"node","desc":"","homepage":"","versions":{"stable":"24.0.0"},\
        "pinned":false,"installed":[\
        {"version":"22.0.0","installed_on_request":false},\
        {"version":"24.0.0","installed_on_request":true}],\
        "dependencies":[]}],"casks":[]}
        """
        let data = try #require(json.data(using: .utf8))
        let response = try JSONDecoder().decode(BrewInfoResponse.self, from: data)
        let pkg = try #require(response.formulae?.first?.toPackage())

        #expect(pkg.version == "24.0.0")
        #expect(pkg.installedVersion == "24.0.0")
        #expect(pkg.installedOnRequest)
    }

    @Test("Outdated JSON uses newest installed version")
    func outdatedUsesNewestInstalledVersion() throws {
        let json = """
        {"formulae":[{"name":"node","installed_versions":["22.0.0","24.0.0"],\
        "current_version":"24.1.0","pinned":false}],\
        "casks":[{"name":"firefox","installed_versions":["122.0","123.0"],\
        "current_version":"124.0"}]}
        """
        let data = try #require(json.data(using: .utf8))
        let response = try JSONDecoder().decode(BrewOutdatedResponse.self, from: data)
        let formula = try #require(response.formulae?.first?.toPackage())
        let cask = try #require(response.casks?.first?.toPackage())

        #expect(formula.version == "24.0.0")
        #expect(formula.installedVersion == "24.0.0")
        #expect(cask.version == "123.0")
        #expect(cask.installedVersion == "123.0")
    }
}

// MARK: - Services Integration Tests

@Suite("BrewService Services Integration")
@MainActor
struct ServicesIntegrationTests {

    @Test("fetchServices uses info format first, falls back to list")
    func fetchServicesFallback() async {
        let mock = MockCommandRunner()
        let service = BrewService(commandRunner: mock)
        let serviceJSON = """
        [{"name":"postgresql@14","running":true,"loaded":true,"pid":1234,\
        "exit_code":0,"user":"test","status":"started"}]
        """
        mock.setResult(
            for: ["services", "info", "--all", "--json"],
            output: serviceJSON
        )

        let services = await service.fetchServices()

        #expect(services.count == 1)
        #expect(services[0].name == "postgresql@14")
    }

    @Test("fetchServices falls back to list when info returns empty")
    func fetchServicesFallbackToList() async {
        let mock = MockCommandRunner()
        let service = BrewService(commandRunner: mock)
        mock.setResult(for: ["services", "info", "--all", "--json"], output: "[]")
        let serviceJSON = """
        [{"name":"redis","running":false,"loaded":false,"status":"none"}]
        """
        mock.setResult(for: ["services", "list", "--json"], output: serviceJSON)

        let services = await service.fetchServices()

        #expect(services.count == 1)
        #expect(services[0].name == "redis")
    }

    @Test("fetchServices returns empty when both service commands fail")
    func fetchServicesDoubleFailure() async {
        let mock = MockCommandRunner()
        let service = BrewService(commandRunner: mock)
        mock.setResult(for: ["services", "info", "--all", "--json"], output: "info failed", success: false)
        mock.setResult(for: ["services", "list", "--json"], output: "list failed", success: false)

        let services = await service.fetchServices()

        #expect(services.isEmpty)
        #expect(mock.executedCommands.contains(["services", "info", "--all", "--json"]))
        #expect(mock.executedCommands.contains(["services", "list", "--json"]))
    }

    @Test("cleanupServices runs brew services cleanup")
    func cleanupServicesRunsCommand() async {
        let mock = MockCommandRunner()
        let service = BrewService(commandRunner: mock)
        mock.setResult(for: ["services", "cleanup"], output: "Cleaned")

        let result = await service.cleanupServices()

        #expect(result.success)
        #expect(result.output == "Cleaned")
        #expect(mock.executedCommands.contains(["services", "cleanup"]))
    }

    @Test("cleanupServices preserves failure result")
    func cleanupServicesPreservesFailure() async {
        let mock = MockCommandRunner()
        let service = BrewService(commandRunner: mock)
        mock.setResult(for: ["services", "cleanup"], output: "cleanup failed", success: false)

        let result = await service.cleanupServices()

        #expect(!result.success)
        #expect(result.output == "cleanup failed")
    }
}
