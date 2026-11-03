import Foundation

/// A table-of-contents row: what the reader's TOC menu shows and where it goes.
struct EPUBTOCEntry: Equatable, Sendable {
    let title: String
    /// Archive path of the chapter the row opens (any fragment is dropped).
    let href: String
    /// Nesting depth: 0 for a top-level row.
    let level: Int
}

/// Table of contents from the book: the EPUB 3 navigation document
/// (`epub:type="toc"`), else the EPUB 2 NCX, else the spine itself.
enum EPUBNavigation {
    static func tableOfContents(
        archive: EPUBArchive,
        package: EPUBPackage,
        chapters: [EPUBChapter]
    ) -> [EPUBTOCEntry] {
        if let nav = package.navigationItem,
           let entries = navigationDocument(archive: archive, href: nav.href),
           !entries.isEmpty {
            return entries
        }
        if let ncx = package.ncxItem,
           let entries = ncxDocument(archive: archive, href: ncx.href),
           !entries.isEmpty {
            return entries
        }
        return chapters.map {
            EPUBTOCEntry(title: $0.title, href: $0.href, level: 0)
        }
    }

    /// The document's `<nav epub:type="toc">` links, in document order.
    static func navigationDocument(archive: EPUBArchive, href: String) -> [EPUBTOCEntry]? {
        guard let data = try? archive.data(for: href),
              let text = decodeText(data) else { return nil }
        let parser = NavParser()
        guard EPUBXML.parse(text, with: parser), !parser.entries.isEmpty else { return nil }
        return parser.entries.compactMap { entry in
            guard let path = EPUBPath.resolve(entry.href, relativeTo: href) else { return nil }
            return EPUBTOCEntry(title: entry.title, href: path, level: entry.level)
        }
    }

    /// EPUB 2's NCX (`navMap` → `navPoint`), in document order.
    static func ncxDocument(archive: EPUBArchive, href: String) -> [EPUBTOCEntry]? {
        guard let data = try? archive.data(for: href),
              let text = decodeText(data) else { return nil }
        let parser = NCXParser()
        guard EPUBXML.parse(text, with: parser), !parser.entries.isEmpty else { return nil }
        return parser.entries.compactMap { entry in
            guard let path = EPUBPath.resolve(entry.href, relativeTo: href) else { return nil }
            return EPUBTOCEntry(title: entry.title, href: path, level: entry.level)
        }
    }

    static func decodeText(_ data: Data) -> String? {
        if let text = String(data: data, encoding: .utf8) { return text }
        return String(data: data, encoding: .windowsCP1252)
    }

    // MARK: - EPUB 3 navigation document

    private final class NavParser: NSObject, XMLParserDelegate {
        struct Entry {
            let title: String
            let href: String
            let level: Int
        }

        private(set) var entries: [Entry] = []
        private var depth = 0
        private var tocNavDepth: Int?
        private var listDepth = 0
        private var anchorDepth: Int?
        private var anchorHref = ""
        private var anchorTitle = ""

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String]
        ) {
            depth += 1
            switch localName(elementName) {
            case "nav":
                let type = attributeDict["epub:type"] ?? attributeDict["type"] ?? ""
                if tocNavDepth == nil,
                   type.split(separator: " ").contains("toc") {
                    tocNavDepth = depth
                }
            case "ol", "ul":
                if tocNavDepth != nil { listDepth += 1 }
            case "a":
                guard tocNavDepth != nil, anchorDepth == nil,
                      let href = attributeDict["href"] else { return }
                anchorDepth = depth
                anchorHref = href
                anchorTitle = ""
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard anchorDepth != nil else { return }
            anchorTitle += string
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            defer { depth -= 1 }
            switch localName(elementName) {
            case "a":
                guard anchorDepth == depth else { return }
                anchorDepth = nil
                let title = anchorTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { return }
                entries.append(Entry(
                    title: title,
                    href: anchorHref,
                    level: max(0, listDepth - 1)
                ))
            case "ol", "ul":
                if tocNavDepth != nil { listDepth = max(0, listDepth - 1) }
            case "nav":
                if tocNavDepth == depth { tocNavDepth = nil }
            default:
                break
            }
        }

        private func localName(_ element: String) -> String {
            guard let colon = element.lastIndex(of: ":") else { return element.lowercased() }
            return String(element[element.index(after: colon)...]).lowercased()
        }
    }

    // MARK: - EPUB 2 NCX

    private final class NCXParser: NSObject, XMLParserDelegate {
        struct Entry {
            let title: String
            let href: String
            let level: Int
        }

        private(set) var entries: [Entry] = []
        private var depth = 0
        /// Depths of the open `navPoint` elements; the count is the nesting.
        private var navPointDepths: [Int] = []
        private var labelDepth: Int?
        private var titleText = ""
        private var labelTitle = ""

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String]
        ) {
            depth += 1
            switch localName(elementName) {
            case "navpoint":
                navPointDepths.append(depth)
            case "navlabel":
                labelDepth = depth
            case "text":
                guard labelDepth != nil else { return }
                titleText = ""
            case "content":
                guard !navPointDepths.isEmpty, let src = attributeDict["src"] else { return }
                let title = labelTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { return }
                entries.append(Entry(
                    title: title,
                    href: src,
                    level: max(0, navPointDepths.count - 1)
                ))
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard labelDepth != nil else { return }
            titleText += string
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            defer { depth -= 1 }
            switch localName(elementName) {
            case "text":
                guard labelDepth != nil else { return }
                labelTitle = titleText.trimmingCharacters(in: .whitespacesAndNewlines)
            case "navlabel":
                labelDepth = nil
            case "navpoint":
                if navPointDepths.last == depth { navPointDepths.removeLast() }
            default:
                break
            }
        }

        private func localName(_ element: String) -> String {
            guard let colon = element.lastIndex(of: ":") else { return element.lowercased() }
            return String(element[element.index(after: colon)...]).lowercased()
        }
    }
}
