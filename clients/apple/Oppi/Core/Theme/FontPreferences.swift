import UIKit

/// User-configurable font preferences, persisted via UserDefaults.
///
/// Two independent axes:
/// - `codeFont`: monospaced font for code blocks, tool output, diffs, inline code
/// - `codeTextScale`: local text scale for dense monospaced/code surfaces
/// - `messageTextScale`: local text scale for chat message body text
/// - `useMonoForMessages`: when true, applies the code font to message body text too
///
/// Keys and scales live in UIKit-free `FontPreferenceStore`. This type owns
/// UIFont loading and the AppFont rebuild lifecycle.
enum FontPreferences {
    static let didChangeNotification = FontPreferenceStore.didChangeNotification
    static var minimumCodeTextScale: CGFloat { CGFloat(FontPreferenceStore.minimumCodeTextScale) }
    static var standardCodeTextScale: CGFloat { CGFloat(FontPreferenceStore.standardCodeTextScale) }
    static var maximumCodeTextScale: CGFloat { CGFloat(FontPreferenceStore.maximumCodeTextScale) }
    static var minimumMessageTextScale: CGFloat { CGFloat(FontPreferenceStore.minimumMessageTextScale) }
    static var standardMessageTextScale: CGFloat { CGFloat(FontPreferenceStore.standardMessageTextScale) }
    static var maximumMessageTextScale: CGFloat { CGFloat(FontPreferenceStore.maximumMessageTextScale) }

    typealias CodeFontFamily = FontPreferenceStore.CodeFontFamily

    // MARK: - Code Text Scale

    /// Current user-facing code text scale. Defaults to 100%, where 100% maps
    /// to the app's readable code baseline. iPhone and iPad use the same scale;
    /// each device persists its own local value through UserDefaults.
    static var codeTextScale: CGFloat {
        CGFloat(FontPreferenceStore.codeTextScale)
    }

    /// Set the code text scale and rebuild all font constants.
    @MainActor
    static func setCodeTextScale(_ scale: CGFloat) {
        FontPreferenceStore.setCodeTextScale(Double(scale))
        AppFont.rebuild()
    }

    static func clampedCodeTextScale(_ scale: CGFloat) -> CGFloat {
        CGFloat(FontPreferenceStore.clampedCodeTextScale(Double(scale)))
    }

    static func codePointSize(
        baseSize: CGFloat,
        idiom: UIUserInterfaceIdiom = currentIdiom
    ) -> CGFloat {
        _ = idiom
        return codePointSize(baseSize: baseSize, codeTextScale: codeTextScale)
    }

    static func codePointSize(baseSize: CGFloat, codeTextScale: CGFloat) -> CGFloat {
        CGFloat(FontPreferenceStore.codePointSize(
            baseSize: Double(baseSize),
            codeTextScale: Double(codeTextScale)
        ))
    }

    static func effectiveCodeTextScale(_ codeTextScale: CGFloat) -> CGFloat {
        CGFloat(FontPreferenceStore.effectiveCodeTextScale(Double(codeTextScale)))
    }

    // MARK: - Message Text Scale

    /// Current chat message body scale. Defaults to 100%.
    static var messageTextScale: CGFloat {
        CGFloat(FontPreferenceStore.messageTextScale)
    }

    /// Set the chat message body scale and rebuild all font constants.
    @MainActor
    static func setMessageTextScale(_ scale: CGFloat) {
        FontPreferenceStore.setMessageTextScale(Double(scale))
        AppFont.rebuild()
    }

    static func clampedMessageTextScale(_ scale: CGFloat) -> CGFloat {
        CGFloat(FontPreferenceStore.clampedMessageTextScale(Double(scale)))
    }

    static func messagePointSize(baseSize: CGFloat) -> CGFloat {
        CGFloat(FontPreferenceStore.messagePointSize(baseSize: Double(baseSize)))
    }

    static func messagePointSize(baseSize: CGFloat, messageTextScale: CGFloat) -> CGFloat {
        CGFloat(FontPreferenceStore.messagePointSize(
            baseSize: Double(baseSize),
            messageTextScale: Double(messageTextScale)
        ))
    }

    static func scaledCodeFont(
        baseSize: CGFloat,
        textStyle: UIFont.TextStyle,
        weight: UIFont.Weight = .regular,
        idiom: UIUserInterfaceIdiom = currentIdiom,
        compatibleWith traitCollection: UITraitCollection? = nil
    ) -> UIFont {
        let baseFont = codeFont.font(
            size: codePointSize(baseSize: baseSize, idiom: idiom),
            weight: weight
        )
        let metrics = UIFontMetrics(forTextStyle: textStyle)
        if let traitCollection {
            return metrics.scaledFont(for: baseFont, compatibleWith: traitCollection)
        }
        return metrics.scaledFont(for: baseFont)
    }

    private static var currentIdiom: UIUserInterfaceIdiom {
        guard Thread.isMainThread else { return .phone }
        return MainActor.assumeIsolated {
            UIDevice.current.userInterfaceIdiom
        }
    }

    /// Current code font family.
    static var codeFont: CodeFontFamily {
        FontPreferenceStore.codeFont
    }

    /// Set the code font and rebuild all font constants.
    @MainActor
    static func setCodeFont(_ family: CodeFontFamily) {
        FontPreferenceStore.setCodeFont(family)
        AppFont.rebuild()
    }

    // MARK: - Mono Messages

    /// Whether message body text uses the selected code font.
    static var useMonoForMessages: Bool {
        FontPreferenceStore.useMonoForMessages
    }

    /// Set mono messages preference and rebuild all font constants.
    @MainActor
    static func setUseMonoForMessages(_ enabled: Bool) {
        FontPreferenceStore.setUseMonoForMessages(enabled)
        AppFont.rebuild()
    }
}

extension FontPreferenceStore.CodeFontFamily {
    /// PostScript name suffix for each weight.
    func postScriptName(weight: UIFont.Weight) -> String? {
        guard let prefix = fontNamePrefix else { return nil }
        let suffix: String
        switch weight {
        case .bold:
            suffix = "Bold"
        case .semibold:
            // Source Code Pro uses "Semibold" (lowercase b), others use "SemiBold"
            suffix = self == .sourceCodePro ? "Semibold" : "SemiBold"
        default:
            suffix = "Regular"
        }
        return "\(prefix)-\(suffix)"
    }

    /// Create a UIFont for the given size and weight. Falls back to system mono if the font can't be loaded.
    func font(size: CGFloat, weight: UIFont.Weight) -> UIFont {
        if let psName = postScriptName(weight: weight),
           let font = UIFont(name: psName, size: size) {
            return font
        }
        return UIFont.monospacedSystemFont(ofSize: size, weight: weight)
    }
}
