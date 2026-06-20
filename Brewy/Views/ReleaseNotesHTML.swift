import SwiftUI

enum ReleaseNotesHTML {
    private static let blockedTagPattern = [
        #"<\s*(script|style|iframe|object|embed|img|source|"#,
        #"video|audio|link|meta|base)\b[^>]*(?:>.*?<\s*/\s*\1\s*>|/?>)"#
    ].joined()

    static func attributedString(from html: String) -> AttributedString? {
        let safeHTML = stripUnsafeMarkup(from: html)
        guard let data = safeHTML.data(using: .utf8),
              let nsAttr = try? NSAttributedString(
                data: data,
                options: [
                    .documentType: NSAttributedString.DocumentType.html,
                    .characterEncoding: String.Encoding.utf8.rawValue
                ],
                documentAttributes: nil
              )
        else { return nil }

        let sanitized = NSMutableAttributedString(attributedString: nsAttr)
        let fullRange = NSRange(location: 0, length: sanitized.length)
        sanitized.enumerateAttribute(.link, in: fullRange) { value, range, _ in
            guard safeLink(from: value) != nil else {
                sanitized.removeAttribute(.link, range: range)
                return
            }
        }
        sanitized.removeAttribute(.attachment, range: fullRange)
        return try? AttributedString(sanitized, including: \.swiftUI)
    }

    static func stripUnsafeMarkup(from html: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: blockedTagPattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return html }
        // Re-run until stable: removing one tag can re-form another
        // (e.g. "<<img>img src=x>" collapses to "<img src=x>"), so a single
        // pass leaks. Each pass strips at least one character, so this ends.
        var current = html
        while true {
            let fullRange = NSRange(current.startIndex..., in: current)
            let stripped = regex.stringByReplacingMatches(in: current, range: fullRange, withTemplate: "")
            if stripped == current { return current }
            current = stripped
        }
    }

    private static func safeLink(from value: Any?) -> URL? {
        switch value {
        case let url as URL:
            return ExternalURLPolicy.url(from: url)
        case let string as String:
            return ExternalURLPolicy.url(from: string)
        default:
            return nil
        }
    }
}
