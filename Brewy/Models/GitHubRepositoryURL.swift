import Foundation

enum GitHubRepositoryURL {
    private static let hosts: Set<String> = ["github.com", "www.github.com"]
    private static let reservedOwners: Set<String> = [
        "about", "apps", "collections", "enterprise", "events", "explore", "features",
        "login", "marketplace", "new", "notifications", "organizations", "orgs", "pricing",
        "pulls", "search", "security", "settings", "signup", "sponsors", "topics", "trending", "users"
    ]

    static func resolve(from candidates: String?...) -> String? {
        for candidate in candidates {
            guard let candidate,
                  let url = ExternalURLPolicy.url(from: candidate),
                  let host = url.host?.lowercased(),
                  hosts.contains(host) else {
                continue
            }

            let pathComponents = url.pathComponents.filter { $0 != "/" }
            guard pathComponents.count >= 2 else { continue }

            let owner = pathComponents[0]
            let rawRepository = pathComponents[1]
            let repository = rawRepository.lowercased().hasSuffix(".git")
                ? String(rawRepository.dropLast(4))
                : rawRepository
            guard !owner.isEmpty,
                  !repository.isEmpty,
                  !reservedOwners.contains(owner.lowercased()) else {
                continue
            }

            var components = URLComponents()
            components.scheme = "https"
            components.host = "github.com"
            components.path = "/\(owner)/\(repository)"
            if let resolved = components.url?.absoluteString {
                return resolved
            }
        }
        return nil
    }
}
