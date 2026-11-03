import Foundation

/// One spine document the reader can open.
struct EPUBChapter: Equatable, Sendable {
    /// Index in the book's reading order, which is what the position stores.
    let index: Int
    /// Archive path of the document.
    let href: String
    /// What the bar and the TOC call it: the TOC's title, else a number.
    let title: String
    /// `linear="no"`: a cover or other auxiliary document.
    let isLinear: Bool
}

enum EPUBBookError: LocalizedError, Equatable {
    case notAnEPUB
    case protected
    case unreadable

    var errorDescription: String? {
        switch self {
        case .notAnEPUB: String(localized: "Not a valid EPUB")
        case .protected: String(localized: "This book is protected")
        case .unreadable: String(localized: "This book can't be opened")
        }
    }
}

/// A whole book: the archive, its package, the reading order, and its table of
/// contents. Chapters parse on demand, so an illustrated book costs its
/// archive bytes plus the chapter in front of the person.
struct EPUBBook {
    let title: String
    let chapters: [EPUBChapter]
    let toc: [EPUBTOCEntry]
    /// The spine's `page-progression-direction`.
    let readsRightToLeft: Bool
    /// Pages, not reflowable text: every chapter needs the web body (slice 5).
    let isFixedLayout: Bool

    private let archive: EPUBArchive
    private let package: EPUBPackage
    /// Chapter index by archive path, built once with the book: the table of
    /// contents, the saved position, and the footer all look chapters up, and a
    /// long book would otherwise compare every row with every chapter.
    private let chapterIndexByHref: [String: Int]

    /// Index of the first linear document, where a new book opens.
    var firstChapterIndex: Int {
        chapters.first { $0.isLinear }?.index ?? 0
    }

    func chapterIndex(forHref href: String) -> Int? {
        chapterIndexByHref[href]
    }

    /// A chapter's Markdown, or the placeholder's reason.
    func source(forChapter index: Int) throws -> EPUBChapterSource {
        guard chapters.indices.contains(index) else { return .unavailable }
        if isFixedLayout { return .unavailable }
        let href = chapters[index].href
        guard let data = try? archive.data(for: href),
              data.count <= EPUBXML.maximumDocumentBytes,
              let document = EPUBNavigation.decodeText(data) else {
            return .unavailable
        }
        return EPUBMarkup.convert(document) ?? .unavailable
    }

    /// Parsed once per open; a broken book is reported with its own message.
    static func open(data: Data) throws -> EPUBBook {
        let archive = EPUBArchive(data: data)
        guard !archive.entryNames.isEmpty else { throw EPUBBookError.notAnEPUB }
        if let problem = protectionProblem(in: archive) { throw problem }
        guard let packagePath = EPUBContainer.packagePath(in: archive),
              let packageData = try? archive.data(for: packagePath),
              let packageText = EPUBNavigation.decodeText(packageData),
              let package = EPUBPackage.parse(packageText, packagePath: packagePath) else {
            throw EPUBBookError.notAnEPUB
        }

        let chapters = package.spine.enumerated().map { index, item in
            EPUBChapter(index: index, href: item.href, title: "", isLinear: item.isLinear)
        }
        let toc = EPUBNavigation.tableOfContents(
            archive: archive,
            package: package,
            chapters: chapters
        )
        // One pass each way, so a book with thousands of chapters and rows
        // costs thousands of lookups rather than millions of comparisons.
        var titlesByHref: [String: String] = [:]
        titlesByHref.reserveCapacity(toc.count)
        for entry in toc where titlesByHref[entry.href] == nil {
            titlesByHref[entry.href] = entry.title
        }
        var indexByHref: [String: Int] = [:]
        indexByHref.reserveCapacity(chapters.count)
        for chapter in chapters where indexByHref[chapter.href] == nil {
            indexByHref[chapter.href] = chapter.index
        }
        let titled = chapters.map { chapter in
            EPUBChapter(
                index: chapter.index,
                href: chapter.href,
                title: titlesByHref[chapter.href]
                    ?? String(localized: "Chapter \(chapter.index + 1)"),
                isLinear: chapter.isLinear
            )
        }
        return EPUBBook(
            title: package.title,
            chapters: titled,
            toc: toc,
            readsRightToLeft: package.pageProgressionIsRTL,
            isFixedLayout: package.isFixedLayout,
            archive: archive,
            package: package,
            chapterIndexByHref: indexByHref
        )
    }

    /// `META-INF/encryption.xml` names what the publisher encrypted or
    /// obfuscated. Font obfuscation is the one legitimate entry: IDPF and Adobe
    /// both mark it with an algorithm URI, which is what the book means, not
    /// the file's extension. Any other encryption is DRM we do not open, and a
    /// file we cannot read is a broken book rather than a protected one.
    private static func protectionProblem(in archive: EPUBArchive) -> EPUBBookError? {
        guard archive.contains(encryptionPath) else { return nil }
        guard let data = try? archive.data(for: encryptionPath),
              let text = EPUBNavigation.decodeText(data) else { return .unreadable }
        let parser = EncryptionParser()
        guard EPUBXML.parse(text, with: parser) else { return .unreadable }
        return parser.hasProtectedReference ? .protected : nil
    }

    private static let encryptionPath = "META-INF/encryption.xml"

    private final class EncryptionParser: NSObject, XMLParserDelegate {
        /// The two font-obfuscation algorithms a publisher may use; the text of
        /// the book itself stays readable behind them.
        private static let fontObfuscationAlgorithms: Set<String> = [
            "http://www.idpf.org/2008/embedding",
            "http://ns.adobe.com/pdf/enc#RC",
        ]

        /// True when something other than an obfuscated font is encrypted.
        private(set) var hasProtectedReference = false
        private var algorithm: String?

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String]
        ) {
            switch elementName.lowercased() {
            case "encrypteddata":
                algorithm = nil
            case "encryptionmethod":
                algorithm = attributeDict["Algorithm"] ?? attributeDict["algorithm"]
            case "cipherreference":
                guard attributeDict["URI"] != nil else { return }
                guard let algorithm, Self.fontObfuscationAlgorithms.contains(algorithm) else {
                    hasProtectedReference = true
                    return
                }
            default:
                break
            }
        }
    }
}
