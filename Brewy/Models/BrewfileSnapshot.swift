import CryptoKit
import Darwin
import Foundation

struct BrewfileSnapshot: Sendable {
    static let maximumByteCount = 1_048_576

    let sourcePath: String
    let data: Data
    let digest: String

    init(sourcePath: String, data: Data) throws {
        guard data.count <= Self.maximumByteCount else {
            throw BrewfileSnapshotError.tooLarge
        }
        self.sourcePath = sourcePath
        self.data = data
        self.digest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func read(from url: URL) throws -> Self {
        let path = url.standardizedFileURL.path
        let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else {
            throw BrewfileSnapshotError.unreadable
        }
        defer { close(descriptor) }

        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG else {
            throw BrewfileSnapshotError.notRegular
        }
        guard status.st_size >= 0,
              status.st_size <= Self.maximumByteCount else {
            throw BrewfileSnapshotError.tooLarge
        }

        var contents = Data()
        contents.reserveCapacity(Int(status.st_size))
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let bytesRead = Darwin.read(descriptor, &buffer, buffer.count)
            if bytesRead == 0 { break }
            if bytesRead < 0 {
                if errno == EINTR { continue }
                throw BrewfileSnapshotError.unreadable
            }
            contents.append(contentsOf: buffer.prefix(bytesRead))
            guard contents.count <= Self.maximumByteCount else {
                throw BrewfileSnapshotError.tooLarge
            }
        }
        return try Self(sourcePath: path, data: contents)
    }
}

struct BrewfileReview: Identifiable {
    let id = UUID()
    let snapshot: BrewfileSnapshot
    let contents: String
    let showsBytes: Bool
    let lineCount: Int

    init(reading url: URL) throws {
        snapshot = try BrewfileSnapshot.read(from: url)
        let hiddenCharacters = CharacterSet.controlCharacters.subtracting(CharacterSet(charactersIn: "\n\r\t"))
        if let text = String(bytes: snapshot.data, encoding: .utf8), snapshot.data.elementsEqual(text.utf8),
           text.rangeOfCharacter(from: hiddenCharacters) == nil {
            contents = text
            showsBytes = false
        } else {
            // Render every byte when the source cannot be shown faithfully as plain text.
            let digits = Array("0123456789abcdef".utf8)
            var hex: [UInt8] = []
            hex.reserveCapacity(snapshot.data.count * 3)
            for (index, byte) in snapshot.data.enumerated() {
                if index > 0 { hex.append(index.isMultiple(of: 16) ? 10 : 32) }
                hex.append(digits[Int(byte >> 4)])
                hex.append(digits[Int(byte & 0x0f)])
            }
            contents = String(decoding: hex, as: Unicode.ASCII.self)
            showsBytes = true
        }
        lineCount = contents.lazy.filter(\.isNewline).count + (contents.last?.isNewline == false ? 1 : 0)
    }
}

enum BrewfileSnapshotError: LocalizedError {
    case unreadable
    case notRegular
    case tooLarge
    case changedSinceReview

    var errorDescription: String? {
        switch self {
        case .unreadable:
            "The Brewfile could not be read."
        case .notRegular:
            "The Brewfile must be a regular file."
        case .tooLarge:
            "The Brewfile exceeds the 1 MB size limit."
        case .changedSinceReview:
            "The selected Brewfile changed. Close this review and open the current file to review it again."
        }
    }
}
