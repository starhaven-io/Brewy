import Foundation

enum UTF8ByteTruncation {
    static func prefix(_ value: String, maxBytes: Int) -> String {
        guard maxBytes > 0 else { return "" }
        let scalars = value.unicodeScalars
        var index = scalars.startIndex
        var byteCount = 0

        while index < scalars.endIndex {
            let width = scalars[index].utf8.count
            guard byteCount + width <= maxBytes else { break }
            byteCount += width
            index = scalars.index(after: index)
        }
        return String(scalars[..<index])
    }

    static func suffix(_ value: String, maxBytes: Int) -> String {
        guard maxBytes > 0 else { return "" }
        let scalars = value.unicodeScalars
        var index = scalars.endIndex
        var byteCount = 0

        while index > scalars.startIndex {
            let previous = scalars.index(before: index)
            let width = scalars[previous].utf8.count
            guard byteCount + width <= maxBytes else { break }
            byteCount += width
            index = previous
        }
        return String(scalars[index...])
    }
}
