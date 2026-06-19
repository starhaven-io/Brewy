import Foundation

enum ExternalURLPolicy {
    private static let allowedSchemes: Set<String> = ["http", "https"]

    static func url(from string: String) -> URL? {
        url(from: URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    static func url(from url: URL?) -> URL? {
        guard let url,
              let scheme = url.scheme?.lowercased(),
              allowedSchemes.contains(scheme),
              url.host?.isEmpty == false else {
            return nil
        }
        return url
    }
}
