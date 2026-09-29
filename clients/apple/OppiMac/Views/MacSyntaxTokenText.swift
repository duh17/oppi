import AppKit
import SwiftUI

/// SwiftUI `Text` paint for short code. Formatting stays AppKit-only and
/// hands back `NSColor` runs; this adapter converts and caches them.
extension MacSyntaxHighlighter {
    private final class TokenRuns: Sendable {
        let value: AttributedString
        init(_ value: AttributedString) { self.value = value }
    }

    // NSCache is internally synchronized.
    nonisolated(unsafe) private static let tokenRunCache: NSCache<NSString, TokenRuns> = {
        let cache = NSCache<NSString, TokenRuns>()
        cache.countLimit = 2_048
        return cache
    }()

    /// Token colors only. Font and the untokenized color come from the view,
    /// so diff rows keep their added/removed/context ink for plain text.
    static func tokenColoredText(
        _ code: String,
        language: SyntaxLanguage?
    ) -> AttributedString {
        guard let language, !code.isEmpty else { return AttributedString(code) }
        let themeID = ThemeRuntimeState.currentThemeID()
        let key = "\(themeID)\u{1}\(language)\u{1}\(code)" as NSString
        if let cached = tokenRunCache.object(forKey: key) {
            return cached.value
        }
        var value = AttributedString(code)
        for run in tokenColorRuns(code, language: language) {
            guard let range = Range(run.range, in: value) else { continue }
            value[range].foregroundColor = Color(nsColor: run.color)
        }
        tokenRunCache.setObject(TokenRuns(value), forKey: key)
        return value
    }
}
