import Foundation
import Testing

@Suite("Internet Access Policy")
struct InternetAccessPolicyTests {

    @Test("Bundles a complete Little Snitch policy")
    func bundlesCompletePolicy() throws {
        let policyURL = try #require(Bundle.main.url(forResource: "InternetAccessPolicy", withExtension: "plist"))
        let data = try Data(contentsOf: policyURL)
        let propertyList = try PropertyListSerialization.propertyList(from: data, format: nil)
        let policy = try #require(propertyList as? [String: Any])

        #expect(policy["DeveloperName"] as? String == "Patrick Linnane")
        #expect((policy["ApplicationDescription"] as? String)?.isEmpty == false)
        #expect(policy["Website"] as? String == "https://github.com/starhaven-io/Brewy")

        let connections = try #require(policy["Connections"] as? [[String: Any]])
        let documentedHosts = Set(connections.flatMap { connection in
            (connection["Host"] as? String)?.split(separator: ",").map(String.init) ?? []
        })
        #expect(documentedHosts.isSuperset(of: [
            "formulae.brew.sh",
            "ghcr.io",
            "api.github.com",
            "raw.githubusercontent.com",
            "github.com",
            "*.github.com",
            "*.githubusercontent.com",
            "*",
            "=*"
        ]))
        #expect(connections.allSatisfy { connection in
            guard let purpose = connection["Purpose"] as? String,
                  let consequences = connection["DenyConsequences"] as? String else {
                return false
            }
            return !purpose.isEmpty && consequences.hasPrefix("If you deny these connections")
        })
    }
}
