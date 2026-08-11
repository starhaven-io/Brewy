@testable import Brewy
import Foundation
import Testing

@Suite("PipeReader", .serialized)
struct PipeReaderTests {

    @Test("Event-driven reader drains data through EOF")
    func drainsThroughEOF() async throws {
        let pipe = Pipe()
        let chunks = LockedChunks()
        let reader = PipeReader(pipe: pipe, label: "EOF test") { chunks.append($0) }
        reader.start()

        try pipe.fileHandleForWriting.write(contentsOf: Data("first".utf8))
        try pipe.fileHandleForWriting.close()
        let data = await Task.detached(priority: .medium) {
            reader.wait { nil }
        }.value

        #expect(String(bytes: data, encoding: .utf8) == "first")
        #expect(chunks.joined() == "first")
    }

    @Test("Forced close preserves data delivered before the deadline")
    func forcedClosePreservesDeliveredData() async throws {
        let pipe = Pipe()
        let chunks = LockedChunks()
        let reader = PipeReader(pipe: pipe, label: "forced-close test") { chunks.append($0) }
        reader.start()
        defer { try? pipe.fileHandleForWriting.close() }

        try pipe.fileHandleForWriting.write(contentsOf: Data("partial".utf8))
        for _ in 0..<1_000 where chunks.joined() != "partial" {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(chunks.joined() == "partial")

        let data = await Task.detached(priority: .medium) {
            reader.wait { .now() + .milliseconds(50) }
        }.value

        #expect(String(bytes: data, encoding: .utf8) == "partial")
    }
}
