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

enum BrewfileSnapshotError: LocalizedError {
    case unreadable
    case notRegular
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .unreadable:
            "The Brewfile could not be read."
        case .notRegular:
            "The Brewfile must be a regular file."
        case .tooLarge:
            "The Brewfile exceeds the 1 MB size limit."
        }
    }
}
