import Foundation

/// Archive paths inside a book: resolved as URLs from the OPF's directory,
/// never written to disk, so a hostile name can only fail to resolve.
enum EPUBPath {
    /// `href` resolved against the directory of `basePath` (the OPF or a
    /// chapter). Nil for an absolute path, a root-escaping `..`, a backslash,
    /// a NUL, or a URL scheme.
    static func resolve(_ href: String, relativeTo basePath: String) -> String? {
        guard let href = normalize(href) else { return nil }
        guard !href.hasPrefix("/") else { return nil }
        var components = directoryComponents(of: basePath)
        for part in href.split(separator: "/", omittingEmptySubsequences: false) {
            switch part {
            case "", ".":
                continue
            case "..":
                guard !components.isEmpty else { return nil }
                components.removeLast()
            default:
                components.append(String(part))
            }
        }
        guard !components.isEmpty else { return nil }
        return components.joined(separator: "/")
    }

    /// The fragment (`#id`) of an href, if any.
    static func fragment(of href: String) -> String? {
        guard let hash = href.firstIndex(of: "#") else { return nil }
        let fragment = String(href[href.index(after: hash)...])
        return fragment.isEmpty ? nil : fragment
    }

    /// A chapter's directory for resolving later references.
    static func directory(of path: String) -> String {
        directoryComponents(of: path).joined(separator: "/")
    }

    static func fileName(of path: String) -> String {
        (path as NSString).lastPathComponent
    }

    /// Percent-decoding plus the refusals every entry name shares.
    static func normalize(_ href: String) -> String? {
        var value = href.trimmingCharacters(in: .whitespacesAndNewlines)
        if let hash = value.firstIndex(of: "#") { value = String(value[..<hash]) }
        if let query = value.firstIndex(of: "?") { value = String(value[..<query]) }
        guard !value.isEmpty,
              !value.contains("\0"),
              !value.contains("\\") else { return nil }
        let decoded = value.removingPercentEncoding ?? value
        guard !decoded.contains("\0"), !decoded.contains("\\") else { return nil }
        // A scheme or authority is a link out of the book, not an entry.
        if let colon = decoded.firstIndex(of: ":"),
           !decoded[..<colon].contains("/"),
           colon != decoded.startIndex {
            return nil
        }
        return decoded
    }

    private static func directoryComponents(of path: String) -> [String] {
        var parts = path.split(separator: "/").map(String.init)
        if !parts.isEmpty { parts.removeLast() }
        return parts
    }
}

// MARK: - Container

/// `META-INF/container.xml`: where the package document lives.
enum EPUBContainer {
    static func packagePath(in archive: EPUBArchive) -> String? {
        guard let data = try? archive.data(for: "META-INF/container.xml"),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let parser = RootfileParser()
        guard EPUBXML.parse(text, with: parser), let path = parser.rootfile else { return nil }
        // OCF paths are relative to the container root; resolve without a base.
        return EPUBPath.resolve(path, relativeTo: "")
    }

    private final class RootfileParser: NSObject, XMLParserDelegate {
        var rootfile: String?

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String]
        ) {
            guard rootfile == nil else { return }
            if let path = attributeDict["full-path"], !path.isEmpty {
                rootfile = path
            }
        }
    }
}

// MARK: - Package document

/// The OPF: metadata title, manifest, spine, and reading direction.
struct EPUBPackage: Equatable {
    struct Item: Equatable {
        let id: String
        let href: String
        let mediaType: String
        let properties: Set<String>
    }

    struct SpineItem: Equatable {
        let idref: String
        let href: String
        /// `linear="no"` marks a cover or other auxiliary document.
        let isLinear: Bool
    }

    let title: String
    let version: String
    let items: [Item]
    /// Spine hrefs in reading order, resolved against the package directory.
    let spine: [SpineItem]
    let pageProgressionIsRTL: Bool
    /// `rendition:layout` = `pre-paginated`: pages, not reflowable text.
    let isFixedLayout: Bool
    /// The EPUB 3 navigation document, if the manifest names one.
    let navigationItem: Item?
    /// The EPUB 2 NCX, if the spine points at one.
    let ncxItem: Item?

    static func parse(_ document: String, packagePath: String) -> EPUBPackage? {
        let parser = PackageParser()
        guard EPUBXML.parse(document, with: parser) else { return nil }
        var items: [Item] = []
        for item in parser.itemRecords {
            guard let path = EPUBPath.resolve(item.href, relativeTo: packagePath) else { continue }
            items.append(Item(
                id: item.id,
                href: path,
                mediaType: item.mediaType,
                properties: item.properties
            ))
        }
        let byId = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let spine: [SpineItem] = parser.spineIdrefs.compactMap { idref, isLinear in
            guard let item = byId[idref] else { return nil }
            return SpineItem(idref: idref, href: item.href, isLinear: isLinear)
        }
        guard !spine.isEmpty else { return nil }
        // The reading order is what the reader draws a title and a table-of-
        // contents row for; past this many documents the file is not a book.
        guard spine.count <= EPUBArchiveLimits.maximumSpineItems else { return nil }
        return EPUBPackage(
            title: parser.title.isEmpty ? EPUBPath.fileName(of: packagePath) : parser.title,
            version: parser.version,
            items: items,
            spine: spine,
            pageProgressionIsRTL: parser.pageProgressionIsRTL,
            isFixedLayout: parser.isFixedLayout,
            navigationItem: items.first { $0.properties.contains("nav") },
            ncxItem: parser.spineToc.flatMap { byId[$0] }
                ?? items.first { $0.mediaType == "application/x-dtbncx+xml" }
        )
    }

    private final class PackageParser: NSObject, XMLParserDelegate {
        var title = ""
        var version = ""
        var itemRecords: [(id: String, href: String, mediaType: String, properties: Set<String>)] = []
        var spineIdrefs: [(String, Bool)] = []
        var spineToc: String?
        var pageProgressionIsRTL = false
        var isFixedLayout = false
        private var titleDepth = 0
        private var titleText = ""
        private var layoutMetaDepth: Int?
        private var layoutMetaText = ""

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String]
        ) {
            switch Self.localName(elementName) {
            case "package":
                version = attributeDict["version"] ?? ""
            case "title":
                // `dc:title`; a later `meta` title must not overwrite it.
                if titleDepth == 0, title.isEmpty {
                    titleDepth = 1
                    titleText = ""
                }
            case "item":
                guard let id = attributeDict["id"],
                      let href = attributeDict["href"] else { return }
                itemRecords.append((
                    id: id,
                    href: href,
                    mediaType: attributeDict["media-type"] ?? "",
                    properties: Self.properties(attributeDict["properties"])
                ))
            case "spine":
                pageProgressionIsRTL = attributeDict["page-progression-direction"] == "rtl"
                spineToc = attributeDict["toc"]
            case "meta":
                guard attributeDict["property"] == "rendition:layout" else { break }
                // EPUB 3 writes the value as an attribute, older tools as the
                // element's text; both mean the same book.
                if Self.isPrePaginated(attributeDict["content"]) {
                    isFixedLayout = true
                } else {
                    layoutMetaDepth = 1
                    layoutMetaText = ""
                }
            case "itemref":
                guard let idref = attributeDict["idref"] else { return }
                spineIdrefs.append((idref, attributeDict["linear"] != "no"))
                // A page-image book can mark each document instead of the book.
                if Self.properties(attributeDict["properties"])
                    .contains("rendition:layout-pre-paginated") {
                    isFixedLayout = true
                }
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if let layoutMetaDepth, layoutMetaDepth > 0 {
                layoutMetaText += string
                return
            }
            guard titleDepth == 1 else { return }
            titleText += string
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            if let _ = layoutMetaDepth, Self.localName(elementName) == "meta" {
                layoutMetaDepth = nil
                isFixedLayout = isFixedLayout || Self.isPrePaginated(layoutMetaText)
                return
            }
            guard Self.localName(elementName) == "title", titleDepth == 1 else { return }
            titleDepth = 0
            title = titleText.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private static func isPrePaginated(_ value: String?) -> Bool {
            value?.trimmingCharacters(in: .whitespacesAndNewlines) == "pre-paginated"
        }

        private static func properties(_ value: String?) -> Set<String> {
            Set((value ?? "").split(separator: " ").map(String.init))
        }

        static func localName(_ element: String) -> String {
            guard let colon = element.lastIndex(of: ":") else { return element.lowercased() }
            return String(element[element.index(after: colon)...]).lowercased()
        }
    }
}
