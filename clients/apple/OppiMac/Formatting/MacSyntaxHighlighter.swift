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

extension FontPreferenceStore {
    static func macCodeFont(weight: NSFont.Weight = .regular) -> NSFont {
        codeFont.macFont(
            size: CGFloat(codePointSize(baseSize: 11)),
            weight: weight
        )
    }

    static func macMessageFont(
        forTextStyle textStyle: NSFont.TextStyle,
        weight: NSFont.Weight = .regular
    ) -> NSFont {
        let baseSize = NSFont.preferredFont(forTextStyle: textStyle).pointSize
        let size = CGFloat(messagePointSize(baseSize: Double(baseSize)))
        if useMonoForMessages {
            return codeFont.macFont(size: size, weight: weight)
        }
        return NSFont.systemFont(ofSize: size, weight: weight)
    }
}

/// macOS syntax-highlighted attributed text adapter.
///
/// Token ranges come from OppiCore's shared provider (`TreeSitterHighlighter`
/// with `SyntaxTokenScanner` fallback). Colors and fonts stay here; Mac does
/// not bake line-number gutters into the attributed string. Displayed source
/// equals the input; token work is bounded by `SyntaxTokenScanner.maxLines`.
enum MacSyntaxHighlighter {
    static func color(for kind: SyntaxTokenKind) -> NSColor? {
        let syntax = ThemeRuntimeState.currentThemeID().appTheme.syntax
        switch kind {
        case .variable:
            return nil
        case .comment:
            return NSColor(syntax.comment)
        case .keyword:
            return NSColor(syntax.keyword)
        case .string:
            return NSColor(syntax.string)
        case .number:
            return NSColor(syntax.number)
        case .type:
            return NSColor(syntax.type)
        case .punctuation:
            return NSColor(syntax.punctuation)
        case .function:
            return NSColor(syntax.function)
        case .operator:
            return NSColor(syntax.operator)
        }
    }

    static func attributedCode(
        _ code: String,
        language: SyntaxLanguage?
    ) -> NSAttributedString {
        let theme = ThemeRuntimeState.currentThemeID().appTheme
        let plainColor = NSColor(theme.syntax.plain)
        let defaultFont = FontPreferenceStore.macCodeFont()
        let result = NSMutableAttributedString(
            string: code,
            attributes: [
                .font: defaultFont,
                .foregroundColor: plainColor,
            ]
        )

        guard let language else { return result }
        let tokenRanges = TreeSitterHighlighter.resolvedTokenRanges(code, language: language)
        let nsLength = result.length
        for token in tokenRanges {
            guard let color = color(for: token.kind) else { continue }
            let range = NSRange(location: token.location, length: token.length)
            guard range.location >= 0, NSMaxRange(range) <= nsLength else { continue }
            result.addAttribute(.foregroundColor, value: color, range: range)
        }

        return result
    }
}
