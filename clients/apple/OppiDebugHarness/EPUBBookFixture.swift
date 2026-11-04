#if DEBUG
import Compression
import Foundation

/// A small, valid book built in memory for the unit tests and the book harness.
/// Entries are stored (method 0) by default, so the bytes here are only the
/// container and the documents: no compressed literals to get wrong. `deflate`
/// writes them the way a real book does (method 8).
///
/// It lives with the harnesses (`dev/testing/apple.md`): fixtures compile only
/// in Debug, while the reader itself never carries one.
enum EPUBFixture {
    struct File {
        let name: String
        let data: Data

        init(name: String, data: Data) {
            self.name = name
            self.data = data
        }

        init(name: String, text: String) {
            self.init(name: name, data: Data(text.utf8))
        }
    }

    /// A book with the given documents. Callers that need EPUB 3 nav, EPUB 2
    /// NCX, or an RTL spine use the builders below, which write a whole package.
    static func archive(files: [File], deflate: Bool = false) -> Data {
        zip(files: files, deflate: deflate)
    }

    /// EPUB 3: `nav.xhtml` with `epub:type="toc"`.
    static func epub3(
        title: String = "A Quiet Book",
        chapterTitles: [String] = ["One", "Two", "Three"],
        rightToLeft: Bool = false,
        deflate: Bool = false,
        paragraphsPerChapter: Int = 12
    ) -> Data {
        let chapters = chapterTitles.enumerated().map { index, chapterTitle in
            (name: String(format: "text/chapter-%02d.xhtml", index + 1), title: chapterTitle)
        }
        var files: [File] = [containerFile()]
        files.append(File(name: "OEBPS/content.opf", text: packageDocument(
            title: title,
            chapters: chapters.enumerated().map { (id: "ch\($0.offset + 1)", href: $0.element.name) },
            navigation: (id: "nav", href: "nav.xhtml"),
            ncx: nil,
            rightToLeft: rightToLeft
        )))
        files.append(File(name: "OEBPS/nav.xhtml", text: navigationDocument(
            title: title,
            chapters: chapters,
            hrefPrefix: ""
        )))
        for (index, chapter) in chapters.enumerated() {
            files.append(File(name: "OEBPS/\(chapter.name)", text: chapterDocument(
                title: chapter.title,
                paragraphs: chapterParagraphs(index: index, title: chapter.title, count: paragraphsPerChapter)
            )))
        }
        return archive(files: files, deflate: deflate)
    }

    /// EPUB 2: an NCX table of contents and `&nbsp;` in the text.
    static func epub2(
        title: String = "An Older Book",
        chapterTitles: [String] = ["First", "Second"]
    ) -> Data {
        let chapters = chapterTitles.enumerated().map { index, chapterTitle in
            (name: String(format: "text/chapter-%02d.xhtml", index + 1), title: chapterTitle)
        }
        var files: [File] = [containerFile()]
        files.append(File(name: "OEBPS/content.opf", text: packageDocument(
            title: title,
            chapters: chapters.enumerated().map { (id: "ch\($0.offset + 1)", href: $0.element.name) },
            navigation: nil,
            ncx: (id: "ncx", href: "toc.ncx"),
            rightToLeft: false,
            version: "2.0"
        )))
        files.append(File(name: "OEBPS/toc.ncx", text: ncxDocument(title: title, chapters: chapters, hrefPrefix: "")))
        for (index, chapter) in chapters.enumerated() {
            files.append(File(name: "OEBPS/\(chapter.name)", text: chapterDocument(
                title: chapter.title,
                paragraphs: [
                    "A narrow room&nbsp;with a window.",
                    "The \(index + 1)st page says&mdash;nothing much.",
                ]
            )))
        }
        return archive(files: files)
    }

    /// Enough paragraphs that a chapter scrolls and has a distinct middle. A
    /// paged reader needs more than one page, so it asks for more.
    static func chapterParagraphs(index: Int, title: String, count: Int = 12) -> [String] {
        (1...max(count, 1)).map { paragraph in
            "Chapter \(index + 1) paragraph \(paragraph) of \(title) says the same calm thing again."
        }
    }

    // MARK: - Documents

    static func containerFile() -> File {
        File(name: "META-INF/container.xml", text: """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """)
    }

    static func packageDocument(
        title: String,
        chapters: [(id: String, href: String)],
        navigation: (id: String, href: String)?,
        ncx: (id: String, href: String)?,
        rightToLeft: Bool,
        version: String = "3.0"
    ) -> String {
        var manifest = chapters.map {
            "<item id=\"\($0.id)\" href=\"\($0.href)\" media-type=\"application/xhtml+xml\"/>"
        }
        if let navigation {
            manifest.append("<item id=\"\(navigation.id)\" href=\"\(navigation.href)\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>")
        }
        if let ncx {
            manifest.append("<item id=\"\(ncx.id)\" href=\"\(ncx.href)\" media-type=\"application/x-dtbncx+xml\"/>")
        }
        let spine = chapters.map { "<itemref idref=\"\($0.id)\"/>" }.joined()
        let direction = rightToLeft ? " page-progression-direction=\"rtl\"" : ""
        let tocAttribute = ncx.map { " toc=\"\($0.id)\"" } ?? ""
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="\(version)" unique-identifier="bookid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:title>\(title)</dc:title>
            <dc:language>en</dc:language>
          </metadata>
          <manifest>\(manifest.joined())</manifest>
          <spine\(tocAttribute)\(direction)>\(spine)</spine>
        </package>
        """
    }

    static func navigationDocument(
        title: String,
        chapters: [(name: String, title: String)],
        hrefPrefix: String
    ) -> String {
        let items = chapters.map {
            "<li><a href=\"\(hrefPrefix)\($0.name)\">\($0.title)</a></li>"
        }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
          <head><title>\(title)</title></head>
          <body>
            <nav epub:type="toc" id="toc"><h1>Contents</h1><ol>\(items)</ol></nav>
          </body>
        </html>
        """
    }

    static func ncxDocument(
        title: String,
        chapters: [(name: String, title: String)],
        hrefPrefix: String
    ) -> String {
        let points = chapters.enumerated().map { index, chapter in
            "<navPoint id=\"np-\(index + 1)\"><navLabel><text>\(chapter.title)</text></navLabel><content src=\"\(hrefPrefix)\(chapter.name)\"/></navPoint>"
        }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
          <head><meta name="dtb:uid" content="fixture"/></head>
          <docTitle><text>\(title)</text></docTitle>
          <navMap>\(points)</navMap>
        </ncx>
        """
    }

    static func chapterDocument(title: String, paragraphs: [String]) -> String {
        let body = paragraphs.map { "<p>\($0)</p>" }.joined(separator: "\n    ")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml">
          <head><title>\(title)</title></head>
          <body>
            <h2>\(title)</h2>
            \(body)
          </body>
        </html>
        """
    }

    // MARK: - ZIP

    /// A ZIP with stored entries (method 0) by default, or deflated ones
    /// (method 8) when `deflate` is set. A stored entry is the container and
    /// nothing else, which makes a failing fixture easier to read; a deflated
    /// one is what a real book writes.
    static func zip(files: [File], deflate: Bool = false) -> Data {
        var output = Data()
        var central = Data()
        for file in files {
            let name = Data(file.name.utf8)
            let crc = crc32(file.data)
            // An entry is only deflated when it shrank, as a ZIP writer decides.
            let deflated = deflate ? Self.deflated(file.data) : nil
            let payload = deflated.flatMap { $0.count < file.data.count ? $0 : nil } ?? file.data
            let method: UInt16 = payload.count < file.data.count ? 8 : 0
            let offset = UInt32(output.count)
            output.append(contentsOf: [0x50, 0x4b, 0x03, 0x04])
            output.appendUInt16(20)
            output.appendUInt16(0)
            output.appendUInt16(method)
            output.appendUInt16(0)
            output.appendUInt16(0)
            output.appendUInt32(crc)
            output.appendUInt32(UInt32(payload.count))
            output.appendUInt32(UInt32(file.data.count))
            output.appendUInt16(UInt16(name.count))
            output.appendUInt16(0)
            output.append(name)
            output.append(payload)

            central.append(contentsOf: [0x50, 0x4b, 0x01, 0x02])
            central.appendUInt16(20)
            central.appendUInt16(20)
            central.appendUInt16(0)
            central.appendUInt16(method)
            central.appendUInt16(0)
            central.appendUInt16(0)
            central.appendUInt32(crc)
            central.appendUInt32(UInt32(payload.count))
            central.appendUInt32(UInt32(file.data.count))
            central.appendUInt16(UInt16(name.count))
            central.appendUInt16(0)
            central.appendUInt16(0)
            central.appendUInt16(0)
            central.appendUInt16(0)
            central.appendUInt32(0)
            central.appendUInt32(offset)
            central.append(name)
        }
        let directoryOffset = UInt32(output.count)
        output.append(central)
        output.append(contentsOf: [0x50, 0x4b, 0x05, 0x06])
        output.appendUInt16(0)
        output.appendUInt16(0)
        output.appendUInt16(UInt16(files.count))
        output.appendUInt16(UInt16(files.count))
        output.appendUInt32(UInt32(central.count))
        output.appendUInt32(directoryOffset)
        output.appendUInt16(0)
        return output
    }

    /// Raw DEFLATE (RFC 1951), which is what method 8 stores and what
    /// `Compression`'s `.zlib` encodes. Nil when nothing came back.
    static func deflated(_ data: Data) -> Data? {
        var output = Data(count: data.count + data.count / 2 + 128)
        let written = output.withUnsafeMutableBytes { destination -> Int in
            guard let base = destination.baseAddress else { return 0 }
            return data.withUnsafeBytes { source -> Int in
                guard let sourceBase = source.baseAddress else { return 0 }
                return compression_encode_buffer(
                    base.assumingMemoryBound(to: UInt8.self),
                    destination.count,
                    sourceBase.assumingMemoryBound(to: UInt8.self),
                    data.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard written > 0 else { return nil }
        return output.prefix(written)
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        append(contentsOf: [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)])
    }

    mutating func appendUInt32(_ value: UInt32) {
        append(contentsOf: [
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF),
        ])
    }
}
#endif
