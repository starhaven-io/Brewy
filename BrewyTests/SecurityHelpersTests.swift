@testable import Brewy
import Foundation
import SwiftUI
import Testing

@Suite("ExternalURLPolicy")
struct ExternalURLPolicyTests {

    @Test("Allows HTTP and HTTPS URLs with hosts")
    func allowsWebURLs() {
        #expect(ExternalURLPolicy.url(from: "https://example.com/path")?.host == "example.com")
        #expect(ExternalURLPolicy.url(from: "http://example.com/path")?.scheme == "http")
    }

    @Test("Rejects local custom and malformed URLs")
    func rejectsUnsafeURLs() {
        #expect(ExternalURLPolicy.url(from: "file:///etc/passwd") == nil)
        #expect(ExternalURLPolicy.url(from: "javascript:alert(1)") == nil)
        #expect(ExternalURLPolicy.url(from: "data:text/plain,hello") == nil)
        #expect(ExternalURLPolicy.url(from: "https:///missing-host") == nil)
    }
}

@Suite("ReleaseNotesHTML")
struct ReleaseNotesHTMLTests {

    @Test("Removes unsafe link attributes")
    func removesUnsafeLinks() throws {
        let html = #"""
        <p>
          <a href="javascript:alert(1)">bad</a>
          <a href="file:///tmp/bad">file</a>
          <a href="https://example.com/release">good</a>
        </p>
        """#

        let attributed = try #require(ReleaseNotesHTML.attributedString(from: html))
        let links = attributed.runs.compactMap(\.link)

        #expect(links == [URL(string: "https://example.com/release")])
    }

    @Test("Strips external resource tags")
    func stripsExternalResourceTags() throws {
        let html = #"<p>Before</p><img src="https://example.com/tracker.png"><p>After</p>"#
        let attributed = try #require(ReleaseNotesHTML.attributedString(from: html))

        #expect(String(attributed.characters).contains("Before"))
        #expect(String(attributed.characters).contains("After"))
        #expect(String(attributed.characters).contains("\u{fffc}") == false)
    }

    @Test("Strips resource tags that re-form after a single pass")
    func stripsReformingResourceTags() {
        // A naive single pass turns this into a live "<img src=...>" that would
        // trigger a network load; the fixed-point strip must remove it entirely.
        let payload = #"<<img>img src="https://evil.example/beacon.png">"#
        let stripped = ReleaseNotesHTML.stripUnsafeMarkup(from: payload)

        #expect(stripped.range(of: "<img", options: .caseInsensitive) == nil)
        #expect(stripped.range(of: "src=", options: .caseInsensitive) == nil)
    }
}
