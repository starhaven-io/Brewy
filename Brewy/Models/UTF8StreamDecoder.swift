import Foundation

/// Decodes UTF-8 arriving in arbitrary chunks, holding back a trailing partial scalar so
/// multi-byte characters split across pipe reads never turn into replacement characters.
struct UTF8StreamDecoder {
    private var pending = Data()

    mutating func decode(_ chunk: Data) -> String {
        var buffer = pending
        buffer.append(chunk)
        pending = Data()
        guard !buffer.isEmpty else { return "" }
        let splitIndex = Self.trailingPartialScalarStart(of: buffer)
        let complete = buffer[buffer.startIndex..<splitIndex]
        pending = Data(buffer[splitIndex...])
        guard !complete.isEmpty else { return "" }
        return Self.lossyDecode(complete)
    }

    /// Emits any held-back bytes (decoded with replacement characters if truly malformed).
    mutating func flush() -> String {
        defer { pending = Data() }
        guard !pending.isEmpty else { return "" }
        return Self.lossyDecode(pending)
    }

    /// Explicitly lossy: streamed console output must render even around malformed bytes,
    /// so errors become U+FFFD instead of dropping the whole chunk.
    private static func lossyDecode(_ data: Data) -> String {
        var result = ""
        result.reserveCapacity(data.count)
        var decoder = UTF8()
        var iterator = data.makeIterator()
        while true {
            switch decoder.decode(&iterator) {
            case .scalarValue(let scalar):
                result.unicodeScalars.append(scalar)
            case .emptyInput:
                return result
            case .error:
                result.unicodeScalars.append("\u{FFFD}")
            }
        }
    }

    /// Index where a trailing incomplete UTF-8 scalar begins, or `endIndex` when the
    /// buffer ends on a scalar boundary (or with bytes no future chunk can repair).
    private static func trailingPartialScalarStart(of data: Data) -> Data.Index {
        var index = data.endIndex
        var continuationBytes = 0
        while index > data.startIndex, continuationBytes < 4 {
            let previous = data.index(before: index)
            let byte = data[previous]
            if byte & 0xC0 == 0x80 {
                index = previous
                continuationBytes += 1
                continue
            }
            let scalarLength: Int
            switch byte {
            case _ where byte & 0x80 == 0x00: scalarLength = 1
            case _ where byte & 0xE0 == 0xC0: scalarLength = 2
            case _ where byte & 0xF0 == 0xE0: scalarLength = 3
            case _ where byte & 0xF8 == 0xF0: scalarLength = 4
            default: return data.endIndex
            }
            return scalarLength > continuationBytes + 1 ? previous : data.endIndex
        }
        return data.endIndex
    }
}
