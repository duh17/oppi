import Foundation
import Testing
@testable import Oppi

// MARK: - ZIP container

@Suite("EPUB archive")
struct EPUBArchiveTests {
    @Test func readsStoredEntries() throws {
        let data = EPUBFixture.epub3()
        let archive = EPUBArchive(data: data)
        #expect(archive.contains("META-INF/container.xml"))
        #expect(archive.contains("OEBPS/content.opf"))
        let container = try archive.data(for: "META-INF/container.xml")
        #expect(String(decoding: container, as: UTF8.self).contains("full-path=\"OEBPS/content.opf\""))
    }

    @Test func refusesAFileThatIsNotAZIP() {
        let archive = EPUBArchive(data: Data("not a zip, just words".utf8))
        #expect(archive.entryNames.isEmpty)
        #expect(throws: EPUBBookError.notAnEPUB) {
            try EPUBBook.open(data: Data("not a zip, just words".utf8))
        }
        // An empty file is not a book either.
        #expect(throws: EPUBBookError.notAnEPUB) { try EPUBBook.open(data: Data()) }
    }

    /// The end record must sit in the last 64 KiB, as the budget says.
    @Test func refusesAnEndRecordOutsideTheWindow() throws {
        var data = EPUBFixture.epub3()
        data.append(Data(repeating: 0, count: EPUBArchiveLimits.endOfCentralDirectoryWindow + 64))
        #expect(throws: EPUBBookError.notAnEPUB) { try EPUBBook.open(data: data) }
    }

    @Test func refusesMoreEntriesThanTheBudget() throws {
        var data = EPUBFixture.epub3()
        let eocd = try #require(EPUBBytes.last(0x0605_4b50, in: data))
        data = EPUBBytes.setUInt16(EPUBBytes.setUInt16(data, at: eocd + 8, 10_001), at: eocd + 10, 10_001)
        #expect(throws: EPUBBookError.notAnEPUB) { try EPUBBook.open(data: data) }
    }

    @Test func refusesAnEntryOutsideTheFile() throws {
        var data = EPUBFixture.epub3()
        let entry = try #require(EPUBBytes.first(0x0201_4b50, in: data))
        let name = try #require(EPUBBytes.centralDirectoryName(in: data, at: entry))
        data = EPUBBytes.setUInt32(data, at: entry + 42, UInt32(data.count + 1_000))
        let archive = EPUBArchive(data: data)
        #expect(archive.contains(name))
        #expect(throws: EPUBArchiveError.self) { try archive.data(for: name) }
    }

    @Test func refusesACompressionMethodWeDoNotRead() throws {
        var data = EPUBFixture.epub3()
        let entry = try #require(EPUBBytes.first(0x0201_4b50, in: data))
        data = EPUBBytes.setUInt16(data, at: entry + 10, 12) // bzip2
        let archive = EPUBArchive(data: data)
        let name = try #require(archive.entryNames.first)
        #expect(throws: EPUBArchiveError.entryUnavailable(name)) { try archive.data(for: name) }
    }

    @Test func refusesAnEncryptedEntry() throws {
        var data = EPUBFixture.epub3()
        let entry = try #require(EPUBBytes.first(0x0201_4b50, in: data))
        data = EPUBBytes.setUInt16(data, at: entry + 8, 0x1)
        let archive = EPUBArchive(data: data)
        let name = try #require(archive.entryNames.first)
        #expect(throws: EPUBArchiveError.entryUnavailable(name)) { try archive.data(for: name) }
    }

    @Test func refusesAnEntryOverItsByteLimit() throws {
        var data = EPUBFixture.epub3()
        let entry = try #require(EPUBBytes.first(0x0201_4b50, in: data))
        data = EPUBBytes.setUInt32(
            data,
            at: entry + 24,
            UInt32(EPUBArchiveLimits.maximumTextEntryBytes + 1)
        )
        let archive = EPUBArchive(data: data)
        let name = try #require(archive.entryNames.first)
        #expect(throws: EPUBArchiveError.entryUnavailable(name)) { try archive.data(for: name) }
    }

    /// Huge declared text from a few stored bytes is a bomb, not a chapter.
    @Test func refusesACompressionRatioBomb() throws {
        var data = EPUBFixture.epub3()
        let entry = try #require(EPUBBytes.first(0x0201_4b50, in: data))
        data = EPUBBytes.setUInt16(data, at: entry + 10, EPUBArchive.deflateMethod)
        data = EPUBBytes.setUInt32(data, at: entry + 24, 2 * 1024 * 1024)
        let archive = EPUBArchive(data: data)
        let name = try #require(archive.entryNames.first)
        #expect(throws: EPUBArchiveError.entryUnavailable(name)) { try archive.data(for: name) }
    }

    /// The path a real book takes: every document deflated (method 8).
    @Test func readsDeflatedEntries() throws {
        let data = EPUBFixture.epub3(deflate: true)
        let archive = EPUBArchive(data: data)
        #expect(archive.contains("OEBPS/text/chapter-02.xhtml"))
        let deflated = try archive.data(for: "OEBPS/text/chapter-02.xhtml")
        #expect(String(decoding: deflated, as: UTF8.self).contains("Chapter 2 paragraph"))

        let book = try EPUBBook.open(data: data)
        #expect(book.chapters.map(\.title) == ["One", "Two", "Three"])
        let source = try book.source(forChapter: 1)
        #expect(source.isAvailable)
        #expect(source.markdown.contains("Chapter 2 paragraph 3 of Two"))
    }

    /// The destination is the declared size, so a payload that inflates past its
    /// declaration cannot become a larger chapter: the entry is corrupt, and
    /// nothing is inflated past the 16 MiB text budget.
    @Test func refusesAPayloadThatInflatesPastItsDeclaredSize() throws {
        let name = "OEBPS/text/chapter-01.xhtml"
        let paragraph = String(repeating: "quiet words ", count: 400)
        var data = EPUBFixture.archive(files: [
            EPUBFixture.containerFile(),
            EPUBFixture.File(name: "OEBPS/content.opf", text: EPUBFixture.packageDocument(
                title: "A Bomb",
                chapters: [(id: "ch1", href: "text/chapter-01.xhtml")],
                navigation: nil,
                ncx: nil,
                rightToLeft: false
            )),
            EPUBFixture.File(name: name, text: EPUBFixture.chapterDocument(
                title: "One",
                paragraphs: [paragraph]
            )),
        ], deflate: true)
        let record = try #require(EPUBBytes.centralDirectoryRecord(named: name, in: data))
        let declared = try #require(EPUBBytes.uint32(in: data, at: record + 24))
        #expect(declared > 1_024)
        // A tenth of the truth: legal under the 16 MiB budget, well past its own
        // declaration once inflated.
        data = EPUBBytes.setUInt32(data, at: record + 24, declared / 10)
        let archive = EPUBArchive(data: data)
        #expect(throws: EPUBArchiveError.corruptEntry(name)) { try archive.data(for: name) }
    }

    @Test func resolvesNamesAsContainerURLs() {
        #expect(EPUBPath.resolve("chapter-01.xhtml", relativeTo: "OEBPS/content.opf") == "OEBPS/chapter-01.xhtml")
        #expect(EPUBPath.resolve("../text/a.xhtml", relativeTo: "OEBPS/content.opf") == "text/a.xhtml")
        #expect(EPUBPath.resolve("text/../a.xhtml", relativeTo: "OEBPS/content.opf") == "OEBPS/a.xhtml")
        #expect(EPUBPath.resolve("../../etc/passwd", relativeTo: "OEBPS/content.opf") == nil)
        #expect(EPUBPath.resolve("/etc/passwd", relativeTo: "OEBPS/content.opf") == nil)
        #expect(EPUBPath.resolve("text\\a.xhtml", relativeTo: "OEBPS/content.opf") == nil)
        #expect(EPUBPath.resolve("tex\u{0}t.xhtml", relativeTo: "OEBPS/content.opf") == nil)
        #expect(EPUBPath.resolve("https://example.com/a.xhtml", relativeTo: "OEBPS/content.opf") == nil)
        #expect(EPUBPath.resolve("a.xhtml#frag", relativeTo: "OEBPS/content.opf") == "OEBPS/a.xhtml")
        #expect(EPUBPath.resolve("my%20chapter.xhtml", relativeTo: "OEBPS/content.opf") == "OEBPS/my chapter.xhtml")
    }
}

// MARK: - XML budget

@Suite("EPUB XML")
struct EPUBXMLTests {
    @Test func refusesEntityDeclarations() {
        let document = """
        <?xml version="1.0"?>
        <!DOCTYPE html [<!ENTITY laugh "ha">]>
        <html><body><p>&laugh;</p></body></html>
        """
        #expect(throws: EPUBXML.Failure.entityDeclaration) { try EPUBXML.hardened(document) }
        #expect(EPUBMarkup.convert(document) == nil)
    }

    @Test func makesNamedHTMLEntitiesNumeric() {
        let hardened = EPUBXML.numericNamedEntities(in: "a&nbsp;b&mdash;c &amp; d &#160;")
        #expect(hardened == "a&#160;b&#8212;c &amp; d &#160;")
    }

    @Test func refusesADocumentOverItsByteBudget() {
        let huge = String(repeating: "a", count: EPUBXML.maximumDocumentBytes + 1)
        #expect(throws: EPUBXML.Failure.tooLarge) { try EPUBXML.hardened(huge) }
    }

    @Test func refusesAnUnknownNamedEntity() {
        let document = """
        <html><body><p>a&bogus;b</p></body></html>
        """
        #expect(EPUBMarkup.convert(document) == nil)
    }
}

// MARK: - Book

@Suite("EPUB book")
struct EPUBBookTests {
    @Test func epub3GivesSpineAndNavigation() throws {
        let book = try EPUBBook.open(data: EPUBFixture.epub3(chapterTitles: ["One", "Two", "Three"]))
        #expect(book.title == "A Quiet Book")
        #expect(book.chapters.count == 3)
        #expect(book.chapters.map(\.title) == ["One", "Two", "Three"])
        #expect(book.toc.map(\.title) == ["One", "Two", "Three"])
        #expect(book.toc.map(\.href) == book.chapters.map(\.href))
        #expect(book.firstChapterIndex == 0)
        #expect(book.isFixedLayout == false)
        #expect(book.readsRightToLeft == false)
    }

    @Test func epub2GivesTheNCXTableOfContents() throws {
        let book = try EPUBBook.open(data: EPUBFixture.epub2(chapterTitles: ["Alpha", "Beta"]))
        #expect(book.chapters.count == 2)
        #expect(book.toc.map(\.title) == ["Alpha", "Beta"])
        let source = try book.source(forChapter: 0)
        #expect(source.isAvailable)
        // `&nbsp;` and `&mdash;` survived as characters, not as markup.
        #expect(source.markdown.contains("narrow room\u{A0}with"))
        #expect(source.markdown.contains("says\u{2014}nothing"))
    }

    @Test func rightToLeftSpineAndDocumentDirection() throws {
        let book = try EPUBBook.open(data: EPUBFixture.epub3(rightToLeft: true))
        #expect(book.readsRightToLeft)
        let document = """
        <html><body dir="rtl"><p>مرحبا</p></body></html>
        """
        let source = try #require(EPUBMarkup.convert(document))
        #expect(source.isRightToLeft == true)
    }

    @Test func protectedBookIsNamedAsSuch() {
        let data = EPUBFixture.archive(files: [
            EPUBFixture.containerFile(),
            EPUBFixture.File(name: "META-INF/encryption.xml", text: """
            <?xml version="1.0"?>
            <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
              <EncryptedData>
                <EncryptionMethod Algorithm="http://www.w3.org/2001/04/xmlenc#aes256-cbc"/>
                <CipherData><CipherReference URI="OEBPS/text/chapter-01.xhtml"/></CipherData>
              </EncryptedData>
            </encryption>
            """),
        ])
        #expect(throws: EPUBBookError.protected) { try EPUBBook.open(data: data) }
        #expect(EPUBBookError.protected.errorDescription == "This book is protected")
    }

    /// A book whose rights file cannot be read is broken, not protected: the
    /// reader can say that instead of guessing the publisher locked it.
    @Test func unreadableEncryptionFileIsNotCalledProtected() {
        let data = EPUBFixture.archive(files: [
            EPUBFixture.containerFile(),
            EPUBFixture.File(name: "META-INF/encryption.xml", text: "<encryption><EncryptedData>"),
        ])
        #expect(throws: EPUBBookError.unreadable) { try EPUBBook.open(data: data) }
        #expect(EPUBBookError.unreadable.errorDescription == "This book can't be opened")
    }

    /// Font obfuscation is named by its algorithm, not by a file extension: the
    /// text of the book is readable behind it either way.
    @Test func obfuscatedFontsAreNotDRM() throws {
        for (path, algorithm) in [
            ("OEBPS/fonts/serif.otf", "http://www.idpf.org/2008/embedding"),
            ("OEBPS/fonts/serif.bin", "http://ns.adobe.com/pdf/enc#RC"),
        ] {
            let book = try makeBook(
                package: singleChapterPackage(),
                encryption: """
                <?xml version="1.0"?>
                <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
                  <EncryptedData>
                    <EncryptionMethod Algorithm="\(algorithm)"/>
                    <CipherData><CipherReference URI="\(path)"/></CipherData>
                  </EncryptedData>
                </encryption>
                """
            )
            #expect(book.chapters.count == 1)
            #expect(try book.source(forChapter: 0).isAvailable)
        }
    }

    /// A page-image book says so either in the package metadata or on each
    /// document; both are `pre-paginated`.
    @Test func fixedLayoutFromTheRenditionAttribute() throws {
        let book = try makeBook(package: singleChapterPackage(
            metadata: "<meta property=\"rendition:layout\" content=\"pre-paginated\"/>"
        ))
        #expect(book.isFixedLayout)
        #expect(try book.source(forChapter: 0).isAvailable == false)
    }

    @Test func fixedLayoutFromAnItemrefProperty() throws {
        let book = try makeBook(package: singleChapterPackage(
            itemrefProperties: " properties=\"rendition:layout-pre-paginated\""
        ))
        #expect(book.isFixedLayout)
        #expect(try book.source(forChapter: 0).isAvailable == false)
    }

    @Test func aReflowableBookStaysReflowable() throws {
        let book = try makeBook(package: singleChapterPackage(
            metadata: "<meta property=\"rendition:layout\" content=\"reflowable\"/>"
        ))
        #expect(book.isFixedLayout == false)
        #expect(try book.source(forChapter: 0).isAvailable)
    }

    @Test func fixedLayoutChaptersAreUnavailable() throws {
        let book = try makeBook(package: singleChapterPackage(
            metadata: "<meta property=\"rendition:layout\">pre-paginated</meta>"
        ))
        #expect(book.isFixedLayout)
        #expect(try book.source(forChapter: 0).isAvailable == false)
    }

    /// A reading order past the budget is a file that pretends to be a book.
    @Test func refusesMoreSpineItemsThanTheBudget() {
        let chapters = (1...(EPUBArchiveLimits.maximumSpineItems + 1)).map {
            (id: "ch\($0)", href: "text/chapter-\($0).xhtml")
        }
        let data = EPUBFixture.archive(files: [
            EPUBFixture.containerFile(),
            EPUBFixture.File(name: "OEBPS/content.opf", text: EPUBFixture.packageDocument(
                title: "Long",
                chapters: chapters,
                navigation: nil,
                ncx: nil,
                rightToLeft: false
            )),
        ])
        #expect(throws: EPUBBookError.notAnEPUB) { try EPUBBook.open(data: data) }
    }

    /// A long but legal book: 5,000 spine items and 5,000 table-of-contents rows.
    /// The reader looks both up by path, so opening stays linear.
    @Test func opensALongButLegalBookQuickly() throws {
        let chapters = (1...EPUBArchiveLimits.maximumSpineItems).map {
            (id: "ch\($0)", href: "text/chapter-\($0).xhtml")
        }
        let rows = chapters.enumerated().map { index, chapter in
            (name: chapter.href, title: "Part \(index + 1)")
        }
        let data = EPUBFixture.archive(files: [
            EPUBFixture.containerFile(),
            EPUBFixture.File(name: "OEBPS/content.opf", text: EPUBFixture.packageDocument(
                title: "Long",
                chapters: chapters,
                navigation: (id: "nav", href: "nav.xhtml"),
                ncx: nil,
                rightToLeft: false
            )),
            EPUBFixture.File(name: "OEBPS/nav.xhtml", text: EPUBFixture.navigationDocument(
                title: "Long",
                chapters: rows,
                hrefPrefix: ""
            )),
        ])
        let started = Date()
        let book = try EPUBBook.open(data: data)
        let elapsed = Date().timeIntervalSince(started)

        #expect(book.chapters.count == EPUBArchiveLimits.maximumSpineItems)
        #expect(book.toc.count == EPUBArchiveLimits.maximumSpineItems)
        #expect(book.chapters.first?.title == "Part 1")
        #expect(book.chapters.last?.title == "Part 5000")
        #expect(book.chapterIndex(forHref: "OEBPS/text/chapter-5000.xhtml") == 4_999)
        #expect(book.chapterIndex(forHref: "OEBPS/text/page-5001.xhtml") == nil)
        // A chapter-by-chapter scan here would take seconds, not milliseconds.
        #expect(elapsed < 2, "opening 5,000 chapters took \(elapsed)s")
    }

    /// A one-chapter book whose package document and rights file are as given.
    private func makeBook(package opf: String, encryption: String? = nil) throws -> EPUBBook {
        var files: [EPUBFixture.File] = [
            EPUBFixture.containerFile(),
            EPUBFixture.File(name: "OEBPS/content.opf", text: opf),
            EPUBFixture.File(name: "OEBPS/text/chapter-01.xhtml", text: EPUBFixture.chapterDocument(
                title: "One",
                paragraphs: ["A page."]
            )),
        ]
        if let encryption {
            files.append(EPUBFixture.File(name: "META-INF/encryption.xml", text: encryption))
        }
        return try EPUBBook.open(data: EPUBFixture.archive(files: files))
    }

    /// The package document of a one-chapter book, with the rendition hints the
    /// fixed-layout tests vary.
    private func singleChapterPackage(
        metadata: String = "",
        itemrefProperties: String = ""
    ) -> String {
        EPUBFixture.packageDocument(
            title: "Pages",
            chapters: [(id: "ch1", href: "text/chapter-01.xhtml")],
            navigation: nil,
            ncx: nil,
            rightToLeft: false
        )
        .replacingOccurrences(of: "</metadata>", with: "\(metadata)</metadata>")
        .replacingOccurrences(
            of: "<itemref idref=\"ch1\"/>",
            with: "<itemref idref=\"ch1\"\(itemrefProperties)/>"
        )
    }

    @Test func verticalWritingFallsBackToThePlaceholder() throws {
        let document = """
        <html><body style="writing-mode: vertical-rl"><p>縦書き</p></body></html>
        """
        #expect(EPUBMarkup.convert(document) == nil)
    }

    /// Every recorded block start is the start of a CommonMark top-level block,
    /// which is what makes a saved ordinal resolve to a reader segment.
    @Test func blockStartsMatchTheMarkdownParser() throws {
        let book = try EPUBBook.open(data: EPUBFixture.epub3())
        for index in book.chapters.indices {
            let source = try book.source(forChapter: index)
            let located = parseCommonMarkLocated(source.markdown)
            let parsedStarts = located.compactMap { $0.lineRange?.lowerBound }
            let recordedStarts = source.blocks.map { $0.markdownStartLine }
            #expect(recordedStarts.count == parsedStarts.count, "chapter \(index)")
            #expect(recordedStarts == parsedStarts, "chapter \(index)")
        }
    }

    @Test func tablesListsAndCodeBecomeMarkdown() throws {
        let document = """
        <html><body>
          <h1>Title</h1>
          <p>Some <em>emphasis</em> and <strong>weight</strong>.</p>
          <ul><li>first</li><li>second</li></ul>
          <blockquote><p>quoted words</p><p>a second quoted paragraph</p></blockquote>
          <pre><code class="language-swift">let x = 1</code></pre>
          <table><tr><th>A</th><th>B</th></tr><tr><td>1</td><td>2</td></tr></table>
          <p>An image: <img src="x.png" alt="a quiet house"/></p>
        </body></html>
        """
        let source = try #require(EPUBMarkup.convert(document))
        #expect(source.markdown.contains("# Title"))
        #expect(source.markdown.contains("*emphasis*"))
        #expect(source.markdown.contains("**weight**"))
        #expect(source.markdown.contains("- first"))
        #expect(source.markdown.contains("> quoted words"))
        #expect(source.markdown.contains("```swift"))
        #expect(source.markdown.contains("| A | B |"))
        #expect(source.markdown.contains("a quiet house"))
        #expect(source.blocks.count >= 6)
        // A multi-paragraph blockquote stays one block, so a recorded start is
        // still a top-level CommonMark block start.
        let located = parseCommonMarkLocated(source.markdown)
        let recorded = source.blocks.map(\.markdownStartLine)
        let parsed = located.compactMap { $0.lineRange?.lowerBound }
        #expect(recorded == parsed, "recorded \(recorded) parsed \(parsed)")
    }
}

// MARK: - Position

@Suite("EPUB reading position")
struct EPUBReadingPositionTests {
    private func store() throws -> EPUBReadingPositionStore {
        let defaults = try #require(UserDefaults(suiteName: "EPUBReadingPositionTests-\(UUID().uuidString)"))
        return EPUBReadingPositionStore(defaults: defaults)
    }

    @Test func savesAndRestoresOneBook() throws {
        let store = try store()
        let key = EPUBReadingPositionStore.key(
            serverId: "server",
            origin: "workspace:one",
            path: "books/novel.epub"
        )
        #expect(store.position(for: key) == nil)
        let position = EPUBReadingPosition(chapterHref: "OEBPS/text/chapter-03.xhtml", blockOrdinal: 7, offsetPoints: 12)
        store.save(position, for: key)
        #expect(store.position(for: key) == position)
        store.clear(key)
        #expect(store.position(for: key) == nil)
    }

    @Test func keepsTheStoreBounded() throws {
        let store = try store()
        for index in 0...EPUBReadingPositionStore.maximumEntries {
            store.save(
                EPUBReadingPosition(chapterHref: "chapter-\(index).xhtml", blockOrdinal: index, offsetPoints: 0),
                for: "book-\(index)",
                now: Date(timeIntervalSince1970: Double(index))
            )
        }
        #expect(store.position(for: "book-0") == nil)
        #expect(store.position(for: "book-\(EPUBReadingPositionStore.maximumEntries)") != nil)
    }

    /// One book is one slot: the same path in two workspaces, two sessions, or
    /// on two servers is a different book each time.
    @Test func keysBooksPerServerOriginAndPath() {
        #expect(
            EPUBReadingPositionStore.key(serverId: "a", origin: "workspace:one", path: "x.epub")
                != EPUBReadingPositionStore.key(serverId: "b", origin: "workspace:one", path: "x.epub")
        )
        #expect(
            EPUBReadingPositionStore.key(serverId: "a", origin: "workspace:one", path: "x.epub")
                != EPUBReadingPositionStore.key(serverId: "a", origin: "workspace:two", path: "x.epub")
        )
        #expect(
            EPUBReadingPositionStore.key(serverId: "a", origin: "workspace:one", path: "x.epub")
                != EPUBReadingPositionStore.key(serverId: "a", origin: "workspace:one", path: "y.epub")
        )
    }
}

// MARK: - Seeded mutation fuzz

/// Seeded like `server/tests/audio-duration.test.ts`: a failing case replays
/// from its seed. The reader must never trap, hang, or return a chapter larger
/// than its budgets on a mutated container.
@Suite("EPUB fuzz")
struct EPUBFuzzTests {
    private static let seed: UInt64 = 0x5EED_A0D1
    private static let cases = 2_000

    @Test func seededMutationsNeverTrap() throws {
        let corpus = Self.corpus()
        var random = SeededRandom(seed: Self.seed)
        let started = Date()
        for _ in 0..<Self.cases {
            let base = corpus[Int(random.next(upperBound: UInt32(corpus.count)))]
            let bytes = mutated(base, random: &random)
            let data = Data(bytes)
            guard let book = try? EPUBBook.open(data: data) else { continue }
            #expect(book.chapters.count <= EPUBArchiveLimits.maximumSpineItems)
            for index in book.chapters.indices.prefix(3) {
                guard let source = try? book.source(forChapter: index) else { continue }
                #expect(source.markdown.utf8.count <= EPUBXML.maximumDocumentBytes)
            }
        }
        // A hang is a failure, not a slow pass.
        #expect(Date().timeIntervalSince(started) < 120)
    }

    /// A deflated book, which is what a real one looks like, plus copies whose
    /// entry names and OPF hrefs already point outside the container: the reader
    /// has to survive both the compressed bytes and the names it must refuse.
    private static func corpus() -> [[UInt8]] {
        var books = [EPUBFixture.epub3(deflate: true)]
        for href in hostileHrefs {
            books.append(deflatedBook(href: href, name: "OEBPS/text/chapter-01.xhtml"))
        }
        for name in hostileNames {
            books.append(deflatedBook(href: "text/chapter-01.xhtml", name: name))
        }
        return books.map { [UInt8]($0) }
    }

    private static let hostileHrefs = [
        "../../etc/passwd",
        "/etc/passwd",
        "https://example.com/chapter.xhtml",
        "text/../../../chapter.xhtml",
        "text/chap\u{0}ter.xhtml",
        "text\\chapter.xhtml",
        "text/chapter-01.xhtml#fragment",
    ]

    private static let hostileNames = [
        "../../chapter.xhtml",
        "/OEBPS/text/chapter-01.xhtml",
        "OEBPS/text\\chapter-01.xhtml",
        "OEBPS/te\u{0}xt/chapter-01.xhtml",
        "./OEBPS/text/chapter-01.xhtml",
    ]

    /// One chapter whose manifest href and archive entry name are as given.
    private static func deflatedBook(href: String, name: String) -> Data {
        EPUBFixture.archive(files: [
            EPUBFixture.containerFile(),
            EPUBFixture.File(name: "OEBPS/content.opf", text: EPUBFixture.packageDocument(
                title: "Hostile",
                chapters: [(id: "ch1", href: href)],
                navigation: nil,
                ncx: nil,
                rightToLeft: false
            )),
            EPUBFixture.File(name: name, text: EPUBFixture.chapterDocument(
                title: "One",
                paragraphs: ["A paragraph of a hostile book."]
            )),
        ], deflate: true)
    }

    /// One to four byte flips, a truncation, an interesting value written into a
    /// size field (ZIP offsets, counts, declared lengths), a hostile byte inside
    /// an entry name, or a copied run of the container.
    private func mutated(_ base: [UInt8], random: inout SeededRandom) -> [UInt8] {
        var bytes = base
        let mutations = 1 + Int(random.next(upperBound: 4))
        for _ in 0..<mutations {
            switch random.next(upperBound: 5) {
            case 0:
                guard !bytes.isEmpty else { continue }
                let at = Int(random.next(upperBound: UInt32(bytes.count)))
                bytes[at] = UInt8(truncatingIfNeeded: random.next(upperBound: 256))
            case 1:
                let length = Int(random.next(upperBound: UInt32(bytes.count)))
                bytes = Array(bytes.prefix(length))
            case 2:
                for field in Self.sizeFieldOffsets(in: bytes).shuffled(using: &random).prefix(2) {
                    let value: UInt32 = [0, 1, 255, 0xFFFF, 0x7FFF_FFFF, 0xFFFF_FFFF]
                        .randomElement(using: &random) ?? 0
                    bytes = EPUBBytes.write(bytes, at: field, value)
                }
            case 3:
                // Dots, separators, and a terminator inside an entry's name.
                guard let region = Self.nameRegions(in: bytes).randomElement(using: &random) else {
                    continue
                }
                let at = region.lowerBound
                    + Int(random.next(upperBound: UInt32(region.count)))
                bytes[at] = [0x2E, 0x2F, 0x5C, 0x00, 0x25, 0x41][Int(random.next(upperBound: 6))]
            default:
                guard bytes.count > 64 else { continue }
                let at = Int(random.next(upperBound: UInt32(bytes.count - 48)))
                let copied = Array(bytes[at..<min(bytes.count, at + 48)])
                bytes.replaceSubrange(at..<at + copied.count, with: copied)
            }
        }
        return bytes
    }

    /// Byte ranges of every central-directory entry name.
    private static func nameRegions(in bytes: [UInt8]) -> [Range<Int>] {
        let data = Data(bytes)
        return EPUBBytes.all(0x0201_4b50, in: data).compactMap { offset in
            guard offset + 46 <= bytes.count else { return nil }
            let length = Int(data[offset + 28]) | Int(data[offset + 29]) << 8
            let start = offset + 46
            guard length > 0, start + length <= bytes.count else { return nil }
            return start..<(start + length)
        }
    }

    /// Size and count fields in the fixture's ZIP records.
    private static func sizeFieldOffsets(in bytes: [UInt8]) -> [Int] {
        var offsets: [Int] = []
        let data = Data(bytes)
        for offset in EPUBBytes.all(0x0201_4b50, in: data) {
            offsets.append(contentsOf: [offset + 20, offset + 24, offset + 42])
        }
        if let eocd = EPUBBytes.last(0x0605_4b50, in: data) {
            offsets.append(contentsOf: [eocd + 10, eocd + 12, eocd + 16])
        }
        return offsets.filter { $0 >= 0 && $0 + 4 <= bytes.count }
    }
}

/// mulberry32, so a seed reproduces a run.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed & 0xFFFF_FFFF
    }

    mutating func next() -> UInt64 {
        state = (state &+ 0x6D2B_79F5) & 0xFFFF_FFFF
        var t = state
        t = (t ^ (t >> 15)) &* (t | 1) & 0xFFFF_FFFF
        t ^= (t &+ ((t &* (t ^ (t >> 7))) | 61)) & 0xFFFF_FFFF
        return (t ^ (t >> 14)) & 0xFFFF_FFFF
    }

    mutating func next(upperBound: UInt32) -> UInt32 {
        guard upperBound > 0 else { return 0 }
        return UInt32(next() % UInt64(upperBound))
    }
}

// MARK: - Byte patching

enum EPUBBytes {
    static func first(_ signature: UInt32, in data: Data) -> Int? {
        all(signature, in: data).first
    }

    static func last(_ signature: UInt32, in data: Data) -> Int? {
        all(signature, in: data).last
    }

    /// The name a central-directory record at `offset` carries.
    static func centralDirectoryName(in data: Data, at offset: Int) -> String? {
        let nameLength = Int(data[offset + 28]) | Int(data[offset + 29]) << 8
        let start = offset + 46
        guard nameLength > 0, start + nameLength <= data.count else { return nil }
        return String(decoding: data[start..<start + nameLength], as: UTF8.self)
    }

    /// The central-directory record of the entry named `name`.
    static func centralDirectoryRecord(named name: String, in data: Data) -> Int? {
        all(0x0201_4b50, in: data).first { centralDirectoryName(in: data, at: $0) == name }
    }

    static func uint32(in data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }

    static func all(_ signature: UInt32, in data: Data) -> [Int] {
        let bytes = [UInt8](data)
        let needle: [UInt8] = [
            UInt8(signature & 0xFF),
            UInt8((signature >> 8) & 0xFF),
            UInt8((signature >> 16) & 0xFF),
            UInt8((signature >> 24) & 0xFF),
        ]
        guard bytes.count >= needle.count else { return [] }
        var result: [Int] = []
        for start in 0...(bytes.count - needle.count) where Array(bytes[start..<start + needle.count]) == needle {
            result.append(start)
        }
        return result
    }

    static func setUInt16(_ data: Data, at offset: Int, _ value: UInt16) -> Data {
        write(data, at: offset, [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)])
    }

    static func setUInt32(_ data: Data, at offset: Int, _ value: UInt32) -> Data {
        write(data, at: offset, [
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF),
        ])
    }

    static func write(_ data: Data, at offset: Int, _ value: [UInt8]) -> Data {
        var result = data
        guard offset >= 0, offset + value.count <= result.count else { return result }
        result.replaceSubrange(offset..<offset + value.count, with: value)
        return result
    }

    static func write(_ bytes: [UInt8], at offset: Int, _ value: UInt32) -> [UInt8] {
        var result = bytes
        let littleEndian: [UInt8] = [
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF),
        ]
        guard offset >= 0, offset + 4 <= result.count else { return result }
        result.replaceSubrange(offset..<offset + 4, with: littleEndian)
        return result
    }
}
