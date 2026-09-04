import Foundation

final class AppcastParser: NSObject, XMLParserDelegate {
    static let maximumFeedByteCount = 1_048_576
    static let maximumDescriptionByteCount = 524_288
    private static let maximumTitleByteCount = 4_096
    private static let maximumDateByteCount = 1_024
    private static let maximumVersionByteCount = 256

    private var currentElement = ""
    private var currentTitle = ""
    private var currentPubDate = ""
    private var currentVersion = ""
    private var currentDescription = ""
    private var release: AppcastRelease?
    private var insideItem = false
    private var currentTitleByteCount = 0
    private var currentPubDateByteCount = 0
    private var currentVersionByteCount = 0
    private var currentDescriptionByteCount = 0
    private var rejected = false

    func parse(data: Data) -> AppcastRelease? {
        guard data.count <= Self.maximumFeedByteCount else { return nil }
        currentElement = ""
        currentTitle = ""
        currentPubDate = ""
        currentVersion = ""
        currentDescription = ""
        release = nil
        insideItem = false
        rejected = false
        resetFieldCounts()

        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldResolveExternalEntities = false
        _ = parser.parse()
        return rejected ? nil : release
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String] = [:]
    ) {
        currentElement = elementName
        if elementName == "item" {
            insideItem = true
            currentTitle = ""
            currentPubDate = ""
            currentVersion = ""
            currentDescription = ""
            resetFieldCounts()
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard insideItem else { return }
        switch currentElement {
        case "title":
            append(
                string,
                to: &currentTitle,
                byteCount: &currentTitleByteCount,
                limit: Self.maximumTitleByteCount,
                parser: parser
            )
        case "pubDate":
            append(
                string,
                to: &currentPubDate,
                byteCount: &currentPubDateByteCount,
                limit: Self.maximumDateByteCount,
                parser: parser
            )
        case "sparkle:shortVersionString":
            append(
                string,
                to: &currentVersion,
                byteCount: &currentVersionByteCount,
                limit: Self.maximumVersionByteCount,
                parser: parser
            )
        case "description":
            append(
                string,
                to: &currentDescription,
                byteCount: &currentDescriptionByteCount,
                limit: Self.maximumDescriptionByteCount,
                parser: parser
            )
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard insideItem, currentElement == "description" else { return }
        if let text = String(data: CDATABlock, encoding: .utf8) {
            append(
                text,
                to: &currentDescription,
                byteCount: &currentDescriptionByteCount,
                limit: Self.maximumDescriptionByteCount,
                parser: parser
            )
        }
    }

    func parser(
        _ parser: XMLParser,
        foundInternalEntityDeclarationWithName name: String,
        value: String?
    ) {
        rejected = true
        parser.abortParsing()
    }

    func parser(
        _ parser: XMLParser,
        foundExternalEntityDeclarationWithName name: String,
        publicID: String?,
        systemID: String?
    ) {
        rejected = true
        parser.abortParsing()
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        if elementName == "item" {
            if release == nil {
                release = AppcastRelease(
                    title: currentTitle.trimmingCharacters(in: .whitespacesAndNewlines),
                    pubDate: currentPubDate.trimmingCharacters(in: .whitespacesAndNewlines),
                    version: currentVersion.trimmingCharacters(in: .whitespacesAndNewlines),
                    descriptionHTML: currentDescription.isEmpty ? nil : currentDescription
                )
            }
            insideItem = false
            parser.abortParsing()
        }
        currentElement = ""
    }

    private func append(
        _ text: String,
        to field: inout String,
        byteCount: inout Int,
        limit: Int,
        parser: XMLParser
    ) {
        let addedByteCount = text.utf8.count
        guard addedByteCount <= limit - byteCount else {
            rejected = true
            parser.abortParsing()
            return
        }
        field += text
        byteCount += addedByteCount
    }

    private func resetFieldCounts() {
        currentTitleByteCount = 0
        currentPubDateByteCount = 0
        currentVersionByteCount = 0
        currentDescriptionByteCount = 0
    }
}
