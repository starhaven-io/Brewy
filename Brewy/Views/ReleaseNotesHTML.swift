import SwiftUI

enum ReleaseNotesHTML {
    static let maximumHTMLByteCount = AppcastParser.maximumDescriptionByteCount
    private static let allowedTags: Set<String> = [
        "a", "b", "blockquote", "br", "code", "em", "h1", "h2", "h3", "h4", "h5", "h6",
        "hr", "i", "li", "ol", "p", "pre", "strong", "ul"
    ]
    private static let hrefRegex = try? NSRegularExpression(
        pattern: #"(?i)(?:^|\s)href\s*=\s*(?:\"([^\"]*)\"|'([^']*)'|([^\s\"'=<>`]+))"#
    )

    @MainActor
    static func attributedString(from html: String) -> AttributedString? {
        guard html.utf8.count <= maximumHTMLByteCount else { return nil }
        let safeHTML = stripUnsafeMarkup(from: html)
        guard safeHTML.utf8.count <= maximumHTMLByteCount,
              let data = safeHTML.data(using: .utf8),
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
        guard html.utf8.count <= maximumHTMLByteCount else { return "" }

        var result = ""
        result.reserveCapacity(html.utf8.count)
        var cursor = html.startIndex

        while cursor < html.endIndex {
            guard html[cursor] == "<" else {
                result.append(html[cursor])
                cursor = html.index(after: cursor)
                continue
            }

            let start = cursor
            var scan = html.index(after: cursor)
            var depth = 1
            var isNested = false
            while scan < html.endIndex, depth > 0 {
                switch html[scan] {
                case "<":
                    depth += 1
                    isNested = true
                case ">":
                    depth -= 1
                default:
                    break
                }
                scan = html.index(after: scan)
            }

            guard depth == 0 else {
                result += " "
                break
            }
            result += isNested ? " " : sanitizedTag(html[start..<scan])
            cursor = scan
        }
        return result.utf8.count <= maximumHTMLByteCount ? result : ""
    }

    private static func sanitizedTag(_ rawTag: Substring) -> String {
        var content = rawTag.dropFirst().dropLast()
        while content.first?.isWhitespace == true { content = content.dropFirst() }
        let isClosing = content.first == "/"
        if isClosing {
            content = content.dropFirst()
            while content.first?.isWhitespace == true { content = content.dropFirst() }
        }

        let name = String(content.prefix { $0.isLetter || $0.isNumber }).lowercased()
        guard allowedTags.contains(name) else { return " " }
        if isClosing { return "</\(name)>" }
        guard name == "a", let href = hrefValue(in: String(content)),
              let url = ExternalURLPolicy.url(from: href) else {
            return "<\(name)>"
        }
        return #"<a href="\#(escapedAttribute(url.absoluteString))">"#
    }

    private static func hrefValue(in tagContent: String) -> String? {
        guard let hrefRegex,
              let match = hrefRegex.firstMatch(
                  in: tagContent,
                  range: NSRange(tagContent.startIndex..., in: tagContent)
              ) else { return nil }
        for index in 1..<match.numberOfRanges where match.range(at: index).location != NSNotFound {
            guard let range = Range(match.range(at: index), in: tagContent) else { continue }
            return String(tagContent[range])
        }
        return nil
    }

    private static func escapedAttribute(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
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
