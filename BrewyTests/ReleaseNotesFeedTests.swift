@testable import Brewy
import Foundation
import Testing

private class OversizedFeedURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "release-feed.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 200,
                  httpVersion: "HTTP/1.1",
                  headerFields: [:]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(
            self,
            didLoad: Data(repeating: 0x41, count: AppcastParser.maximumFeedByteCount + 1)
        )
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("Release Notes Feed", .serialized)
struct ReleaseNotesFeedTests {
    @Test("streaming rejects an oversized response without Content-Length")
    func rejectsUnknownLengthOversizedResponse() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OversizedFeedURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let url = try #require(URL(string: "https://release-feed.test/appcast.xml"))

        await #expect(throws: ReleaseNotesFeed.FeedError.self) {
            try await ReleaseNotesFeed.load(from: url, session: session)
        }
    }

    @Test("parser rejects entity declarations before expansion")
    func rejectsEntityDeclarations() throws {
        let xml = """
        <!DOCTYPE rss [<!ENTITY repeated "release notes">]>
        <rss><channel><item><title>&repeated;</title></item></channel></rss>
        """
        let data = try #require(xml.data(using: .utf8))

        #expect(AppcastParser().parse(data: data) == nil)
    }

    @Test("real rendering path converts sanitized HTML on the main actor")
    @MainActor
    func rendersReleaseNotesThroughRealPath() async throws {
        let xml = """
        <rss xmlns:sparkle="https://www.andymatuschak.org/xml-namespaces/sparkle">
          <channel><item>
            <title>Brewy 1.2.3</title>
            <sparkle:shortVersionString>1.2.3</sparkle:shortVersionString>
            <description><![CDATA[<p>Hello <strong>Brewy</strong></p>]]></description>
          </item></channel>
        </rss>
        """
        let data = try #require(xml.data(using: .utf8))

        let (release, notes) = await ReleaseNotesFeed.parseAndRender(data)

        #expect(release?.version == "1.2.3")
        #expect(notes.map { String($0.characters) }?.contains("Hello Brewy") == true)
    }
}
