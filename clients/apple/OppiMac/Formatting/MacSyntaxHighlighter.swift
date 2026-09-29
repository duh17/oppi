import AppKit
import CoreText
import Foundation

/// Process-scoped registration of one bundled coding-font family.
/// Launch no longer ATS-registers all five families; Home chrome uses system type.
enum MacBundledCodeFontRegistration {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var registered: Set<String> = []

    static func fontFileURLs(in folder: URL) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil
        )) ?? []
        return urls.filter { ["ttf", "otf"].contains($0.pathExtension.lowercased()) }
    }

    static func ensureRegistered(_ family: FontPreferenceStore.CodeFontFamily) {
        guard let folderName = family.fontNamePrefix else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !registered.contains(folderName) else { return }
        registered.insert(folderName)
        guard let folder = Bundle.main.resourceURL?
            .appendingPathComponent("Fonts", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true) else {
            return
        }
        for url in fontFileURLs(in: folder) {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}

extension FontPreferenceStore.CodeFontFamily {
    fileprivate func macPostScriptName(weight: NSFont.Weight) -> String? {
        guard let prefix = fontNamePrefix else { return nil }
        let suffix: String
        switch weight {
        case .bold:
            suffix = "Bold"
        case .semibold:
            suffix = self == .sourceCodePro ? "Semibold" : "SemiBold"
        default:
            suffix = "Regular"
        }
        return "\(prefix)-\(suffix)"
    }

    fileprivate func macFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        MacBundledCodeFontRegistration.ensureRegistered(self)
        if let name = macPostScriptName(weight: weight),
           let font = NSFont(name: name, size: size) {
            return font
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }
}

/// Mac reading sizes at 100% zoom. macOS text styles are tuned for dense
/// controls (13 pt body), which reads like a log on a desktop display at
/// timeline distance. The shared OppiCore scale ranges (iOS owns them) stay
/// untouched; ⌘+ / ⌘- / ⌘0 multiply these Mac bases.
enum MacReadingType {
    /// 12 pt × the shared 1.1 code baseline → 13 pt code at 100%.
    static let codeBaseSize: Double = 12
    /// Lifts every message text style so body lands on 15 pt at 100%.
    static let messageStyleScale: Double = 15.0 / 13.0
    /// Inline code inside prose, relative to the surrounding text size.
    /// Same proportion as iOS (subheadline mono inside body prose).
    static let inlineCodeRelativeSize: CGFloat = 0.9
}

extension FontPreferenceStore {
    static func macCodeFont(weight: NSFont.Weight = .regular) -> NSFont {
        codeFont.macFont(
            size: CGFloat(codePointSize(baseSize: MacReadingType.codeBaseSize)),
            weight: weight
        )
    }

    /// Monospaced font sized relative to the prose it sits in (inline code,
    /// tool header titles next to message text), in the user's code family.
    static func macCodeFont(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        codeFont.macFont(size: size.rounded(), weight: weight)
    }

    static func macMessagePointSize(forTextStyle textStyle: NSFont.TextStyle) -> CGFloat {
        let styleSize = Double(NSFont.preferredFont(forTextStyle: textStyle).pointSize)
        return CGFloat(messagePointSize(
            baseSize: (styleSize * MacReadingType.messageStyleScale).rounded()
        ))
    }

    static func macMessageFont(
        forTextStyle textStyle: NSFont.TextStyle,
        weight: NSFont.Weight = .regular
    ) -> NSFont {
        let size = macMessagePointSize(forTextStyle: textStyle)
        if useMonoForMessages {
            return codeFont.macFont(size: size, weight: weight)
        }
        return NSFont.systemFont(ofSize: size, weight: weight)
    }

    /// Mono for inline code in a message: tracks message zoom, not code zoom,
    /// so a code span stays proportional to the words around it.
    static func macInlineCodeFont(forTextStyle textStyle: NSFont.TextStyle) -> NSFont {
        macCodeFont(
            size: macMessagePointSize(forTextStyle: textStyle) * MacReadingType.inlineCodeRelativeSize
        )
    }
}

/// macOS syntax-highlighted attributed text adapter.
///
/// Token ranges come from OppiCore's shared provider (`TreeSitterHighlighter`
/// with `SyntaxTokenScanner` fallback). Colors and fonts stay here; Mac does
/// not bake line-number gutters into the attributed string. Displayed source
/// equals the input; token work is bounded by `SyntaxTokenScanner.maxLines`.
enum MacSyntaxHighlighter {
    /// Token colors resolved once per highlight from the cached runtime
    /// palette. `ThemeID.appTheme` rebuilds custom themes from stored JSON,
    /// so it must never run per token.
    private struct Paint {
        let plain: NSColor
        let keyword: NSColor
        let string: NSColor
        let comment: NSColor
        let number: NSColor
        let type: NSColor
        let punctuation: NSColor
        let function: NSColor
        let op: NSColor

        init(palette: ThemePalette) {
            plain = NSColor(palette.fg)
            keyword = NSColor(palette.syntaxKeyword)
            string = NSColor(palette.syntaxString)
            comment = NSColor(palette.syntaxComment)
            number = NSColor(palette.syntaxNumber)
            type = NSColor(palette.syntaxType)
            punctuation = NSColor(palette.syntaxPunctuation)
            function = NSColor(palette.syntaxFunction)
            op = NSColor(palette.syntaxOperator)
        }

        func color(for kind: SyntaxTokenKind) -> NSColor? {
            switch kind {
            case .variable: nil
            case .comment: comment
            case .keyword: keyword
            case .string: string
            case .number: number
            case .type: type
            case .punctuation: punctuation
            case .function: function
            case .operator: op
            }
        }
    }

    /// Rows re-evaluate their body on every live update and on scroll
    /// materialization; tree-sitter work must not ride along. Keyed by
    /// everything that changes the painted result.
    // NSCache is thread-safe. The compiler cannot see that.
    nonisolated(unsafe) private static let cache: NSCache<NSString, NSAttributedString> = {
        let cache = NSCache<NSString, NSAttributedString>()
        cache.countLimit = 256
        return cache
    }()

    static func color(for kind: SyntaxTokenKind) -> NSColor? {
        Paint(palette: ThemeRuntimeState.currentPalette()).color(for: kind)
    }

    static func attributedCode(
        _ code: String,
        language: SyntaxLanguage?
    ) -> NSAttributedString {
        let defaultFont = FontPreferenceStore.macCodeFont()
        let themeID = ThemeRuntimeState.currentThemeID()
        let key = "\(themeID)\u{1}\(defaultFont.fontName)\u{1}\(defaultFont.pointSize)\u{1}\(language.map { "\($0)" } ?? "-")\u{1}\(code)" as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }

        let paint = Paint(palette: ThemeRuntimeState.currentPalette())
        let result = NSMutableAttributedString(
            string: code,
            attributes: [
                .font: defaultFont,
                .foregroundColor: paint.plain,
            ]
        )

        if let language {
            let tokenRanges = TreeSitterHighlighter.resolvedTokenRanges(code, language: language)
            let nsLength = result.length
            for token in tokenRanges {
                guard let color = paint.color(for: token.kind) else { continue }
                let range = NSRange(location: token.location, length: token.length)
                guard range.location >= 0, NSMaxRange(range) <= nsLength else { continue }
                result.addAttribute(.foregroundColor, value: color, range: range)
            }
        }

        let painted = NSAttributedString(attributedString: result)
        cache.setObject(painted, forKey: key)
        return painted
    }

    /// Token colors for short code (a command, one diff line). Ranges are
    /// UTF-16 offsets into `code`; untokenized text has no entry so callers
    /// keep their own row ink. SwiftUI conversion lives in the view layer.
    static func tokenColorRuns(
        _ code: String,
        language: SyntaxLanguage
    ) -> [(range: NSRange, color: NSColor)] {
        let paint = Paint(palette: ThemeRuntimeState.currentPalette())
        let nsLength = (code as NSString).length
        return TreeSitterHighlighter.resolvedTokenRanges(code, language: language).compactMap { token in
            guard let color = paint.color(for: token.kind) else { return nil }
            let range = NSRange(location: token.location, length: token.length)
            guard range.location >= 0, NSMaxRange(range) <= nsLength else { return nil }
            return (range, color)
        }
    }
}
