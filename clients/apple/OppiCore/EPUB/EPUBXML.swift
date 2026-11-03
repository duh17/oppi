import Foundation

/// The XML half of a book, hardened for untrusted input.
///
/// `XMLParser` never resolves external entities (`shouldResolveExternalEntities`
/// stays false, so a DTD is not fetched), and any `<!ENTITY` declaration is
/// refused before the parser sees it: internal entities are how a few hundred
/// bytes expand into gigabytes. EPUB 2 files are XHTML written as SGML-ish
/// XML and use named HTML entities (`&nbsp;`), which XML has no table for, so
/// the common ones are rewritten to numeric references first.
enum EPUBXML {
    /// The largest XHTML document this slice will parse.
    static let maximumDocumentBytes = 4 * 1024 * 1024

    /// HTML named entities seen in EPUB 2 content documents. Anything else
    /// fails XML parsing, and the chapter falls back to its placeholder.
    static let namedEntities: [String: UInt32] = [
        "amp": 0x26, "lt": 0x3C, "gt": 0x3E, "quot": 0x22, "apos": 0x27,
        "nbsp": 0xA0, "iexcl": 0xA1, "cent": 0xA2, "pound": 0xA3, "curren": 0xA4,
        "yen": 0xA5, "sect": 0xA7, "uml": 0xA8, "copy": 0xA9, "ordf": 0xAA,
        "laquo": 0xAB, "not": 0xAC, "shy": 0xAD, "reg": 0xAE, "macr": 0xAF,
        "deg": 0xB0, "plusmn": 0xB1, "sup2": 0xB2, "sup3": 0xB3, "acute": 0xB4,
        "micro": 0xB5, "para": 0xB6, "middot": 0xB7, "cedil": 0xB8, "sup1": 0xB9,
        "ordm": 0xBA, "raquo": 0xBB, "frac14": 0xBC, "frac12": 0xBD, "frac34": 0xBE,
        "iquest": 0xBF, "times": 0xD7, "divide": 0xF7,
        "ndash": 0x2013, "mdash": 0x2014, "lsquo": 0x2018, "rsquo": 0x2019,
        "sbquo": 0x201A, "ldquo": 0x201C, "rdquo": 0x201D, "bdquo": 0x201E,
        "dagger": 0x2020, "Dagger": 0x2021, "bull": 0x2022, "hellip": 0x2026,
        "permil": 0x2030, "prime": 0x2032, "Prime": 0x2033, "lsaquo": 0x2039,
        "rsaquo": 0x203A, "oline": 0x203E, "frasl": 0x2044, "euro": 0x20AC,
        "trade": 0x2122, "larr": 0x2190, "uarr": 0x2191, "rarr": 0x2192,
        "darr": 0x2193, "harr": 0x2194, "minus": 0x2212, "lowast": 0x2217,
        "ne": 0x2260, "le": 0x2264, "ge": 0x2265, "ensp": 0x2002, "emsp": 0x2003,
        "thinsp": 0x2009, "zwnj": 0x200C, "zwj": 0x200D, "lrm": 0x200E, "rlm": 0x200F,
        "eacute": 0xE9, "egrave": 0xE8, "agrave": 0xE0, "ccedil": 0xE7,
        "aacute": 0xE1, "iacute": 0xED, "oacute": 0xF3, "uacute": 0xFA,
        "ntilde": 0xF1, "ouml": 0xF6, "auml": 0xE4, "uuml": 0xFC, "szlig": 0xDF,
    ]

    enum Failure: Error, Equatable {
        case tooLarge
        case entityDeclaration
        case unparseable
    }

    /// Text a parser can read safely: entity declarations refused, named HTML
    /// entities made numeric, size bounded.
    static func hardened(_ text: String) throws -> String {
        guard text.utf8.count <= maximumDocumentBytes else { throw Failure.tooLarge }
        guard !text.contains("<!ENTITY") else { throw Failure.entityDeclaration }
        guard text.contains("&") else { return stripBOM(text) }
        return numericNamedEntities(in: stripBOM(text))
    }

    /// A parser for hardened text. Returns nil when the text is not well-formed
    /// XML, which sends the chapter to its placeholder.
    static func parser(forHardened text: String) -> XMLParser? {
        guard let data = text.data(using: .utf8) else { return nil }
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        return parser
    }

    /// Parse `document` with a fresh delegate. False when the bytes are not
    /// well-formed XML or the delegate refused them.
    static func parse(_ document: String, with delegate: XMLParserDelegate) -> Bool {
        guard let hardened = try? hardened(document),
              let parser = parser(forHardened: hardened) else { return false }
        parser.delegate = delegate
        return parser.parse()
    }

    private static func stripBOM(_ text: String) -> String {
        text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
    }

    /// `&nbsp;` → `&#160;`, leaving `&amp;`-style predefined and `&#…;` numeric
    /// references alone. Unknown names stay as written and fail the parse.
    static func numericNamedEntities(in text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        var rest = Substring(text)
        while let ampersand = rest.firstIndex(of: "&") {
            result += rest[rest.startIndex..<ampersand]
            let after = rest.index(after: ampersand)
            // A reference is short; a bare `&` must not rescan the document.
            let windowEnd = rest.index(after, offsetBy: 33, limitedBy: rest.endIndex) ?? rest.endIndex
            guard let semicolon = rest[after..<windowEnd].firstIndex(of: ";") else {
                result += "&"
                rest = rest[after...]
                continue
            }
            let name = rest[after..<semicolon]
            // `&amp;` and friends are XML's own; only HTML names are rewritten.
            let isPredefined = ["amp", "lt", "gt", "quot", "apos"].contains(String(name))
            if !name.isEmpty,
               !name.hasPrefix("#"),
               !isPredefined,
               let scalar = namedEntities[String(name)] {
                result += "&#\(scalar);"
            } else {
                result += "&\(name);"
            }
            rest = rest[rest.index(after: semicolon)...]
        }
        result += rest
        return result
    }
}
