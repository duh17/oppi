import SwiftUI
import UIKit

/// The one owner of resolved UIKit fonts for reading surfaces.
///
/// Two families of roles, each with one in-app size control:
/// - Code roles (`mono*`): the selected code font at fixed 100% sizes times
///   Code Text Size. Dynamic Type does not scale them; dense code, diffs,
///   and the terminal grid use the in-app control instead.
/// - Message roles (`message*`): system body (Dynamic Type) times Message
///   Text Size, with headings and inline code as fixed ratios of the body.
///
/// Full-screen readers multiply these by their own reader text scale.
/// SwiftUI chrome uses the `Font.app*` constants below.
enum AppFont {
    // MARK: - Code roles (selected code font × Code Text Size)
    //
    // `nonisolated(unsafe)` because these are written only from @MainActor
    // (rebuild()) and read from UI code plus the detached MarkdownPrewarmer.
    // UIFont is immutable once created; the prewarmer keys its cache entries
    // by the `revision` it captured on main, so a read that straddles a
    // rebuild is never served as current.

    /// 11pt at 100% — line numbers, counters, secondary labels
    nonisolated(unsafe) private(set) static var monoSmall = UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    nonisolated(unsafe) private(set) static var monoSmallSemibold = UIFont.monospacedSystemFont(ofSize: 11, weight: .semibold)

    /// 12pt at 100% — ANSI terminal output, labels, raw HTML blocks
    nonisolated(unsafe) private(set) static var mono = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    nonisolated(unsafe) private(set) static var monoBold = UIFont.monospacedSystemFont(ofSize: 12, weight: .bold)

    /// 13pt at 100% — code blocks, tool output, diffs, full-screen code, terminal
    nonisolated(unsafe) private(set) static var monoMedium = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    nonisolated(unsafe) private(set) static var monoMediumBold = UIFont.monospacedSystemFont(ofSize: 13, weight: .bold)
    nonisolated(unsafe) private(set) static var monoMediumSemibold = UIFont.monospacedSystemFont(ofSize: 13, weight: .semibold)

    /// 14pt at 100% — the file editor
    nonisolated(unsafe) private(set) static var monoEditor = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)

    /// 15pt at 100% — source shown inside rendered documents and exports
    nonisolated(unsafe) private(set) static var monoDocument = UIFont.monospacedSystemFont(ofSize: 15, weight: .regular)

    /// Fixed 15pt in the code font — prompt icons, spinner characters
    nonisolated(unsafe) private(set) static var monoLarge = UIFont.monospacedSystemFont(ofSize: 15, weight: .regular)
    nonisolated(unsafe) private(set) static var monoLargeSemibold = UIFont.monospacedSystemFont(ofSize: 15, weight: .semibold)

    // MARK: - Message roles (Dynamic Type body × Message Text Size)

    /// Message body font — system body by default, or the selected mono font
    /// when `FontPreferences.useMonoForMessages` is enabled.
    nonisolated(unsafe) private(set) static var messageBody: UIFont = .preferredFont(forTextStyle: .body)

    /// Inline code inside message prose, in the code font at Apple's
    /// subheadline-to-body ratio (15/17). It sits in a body line, so it
    /// follows the body's Dynamic Type and Message Text Size, not Code Text Size.
    nonisolated(unsafe) private(set) static var messageInlineCode = UIFont.monospacedSystemFont(ofSize: 15, weight: .regular)

    /// Markdown headings H1–H6, sized as fixed ratios of `messageBody`
    /// (21, 19, 17, 17, 15, 15 at a 17pt body) so hierarchy holds at every
    /// Dynamic Type size and Message Text Size.
    nonisolated(unsafe) private(set) static var messageHeadings: [UIFont] = makeMessageHeadings(bodySize: 17)

    /// Heading font for a markdown heading level; levels past 6 use H6.
    static func messageHeading(level: Int) -> UIFont {
        messageHeadings[min(max(level, 1), messageHeadings.count) - 1]
    }

    /// Changes on every `rebuild()`. Render configurations that cache
    /// attributed text compare it so a font change re-renders visible rows.
    nonisolated(unsafe) private(set) static var revision: UInt64 = 0

    /// Posted on the main thread at the end of every `rebuild()`, after the
    /// new fonts are readable. Font consumers observe this, not the store's
    /// preference notification, which fires before the rebuild.
    static let didRebuildNotification = Notification.Name("AppFontDidRebuild")

    // MARK: - System (UIKit, non-monospaced) — these don't change

    /// 11pt — metadata labels, line counts
    static let systemSmall = UIFont.systemFont(ofSize: 11)

    /// 13pt semibold — toast feedback ("Copied")
    static let systemFeedback = UIFont.systemFont(ofSize: 13, weight: .semibold)

    /// 14pt medium — toast feedback ("Saved")
    static let systemFeedbackMedium = UIFont.systemFont(ofSize: 14, weight: .medium)

    // MARK: - Rebuild

    /// Rebuild all dynamic font constants from current preferences and the
    /// current Dynamic Type size. Called on startup, when font preferences
    /// change, and when the content size category changes.
    @MainActor
    static func rebuild() {
        let family = FontPreferences.codeFont
        // Unrounded, so every 5% step of the Code Text Size slider changes size.
        let codeScale = FontPreferences.codeTextScale
        func code(_ size: CGFloat, _ weight: UIFont.Weight) -> UIFont {
            family.font(size: size * codeScale, weight: weight)
        }

        monoSmall = code(11, .regular)
        monoSmallSemibold = code(11, .semibold)
        mono = code(12, .regular)
        monoBold = code(12, .bold)
        monoMedium = code(13, .regular)
        monoMediumBold = code(13, .bold)
        monoMediumSemibold = code(13, .semibold)
        monoEditor = code(14, .regular)
        monoDocument = code(15, .regular)

        monoLarge = family.font(size: 15, weight: .regular)
        monoLargeSemibold = family.font(size: 15, weight: .semibold)

        // Message body
        let bodyFont = UIFont.preferredFont(forTextStyle: .body)
        let messagePointSize = FontPreferences.messagePointSize(baseSize: bodyFont.pointSize)
        if FontPreferences.useMonoForMessages {
            messageBody = family.font(size: messagePointSize, weight: .regular)
        } else {
            messageBody = bodyFont.withSize(messagePointSize)
        }
        messageInlineCode = family.font(size: messagePointSize * 15 / 17, weight: .regular)
        messageHeadings = makeMessageHeadings(bodySize: messagePointSize)
        revision &+= 1
        NotificationCenter.default.post(name: didRebuildNotification, object: nil)
    }

    private static func makeMessageHeadings(bodySize: CGFloat) -> [UIFont] {
        let levels: [(size: CGFloat, weight: UIFont.Weight)] = [
            (21, .bold), (19, .semibold), (17, .semibold), (17, .medium), (15, .medium), (15, .regular),
        ]
        return levels.map { .systemFont(ofSize: bodySize * $0.size / 17, weight: $0.weight) }
    }
}

// MARK: - SwiftUI Font Constants

extension Font {
    // -- Badge / indicator fonts (tiny, fixed size) --

    /// 7pt bold — unread counts, context badges
    static let appBadgeCount = Font.system(size: 7, weight: .bold)

    /// 8pt bold — small count badges
    static let appBadge = Font.system(size: 8, weight: .bold)

    /// 8pt semibold — small indicator labels
    static let appBadgeLight = Font.system(size: 8, weight: .semibold)

    /// 9pt semibold — tag labels, model badges
    static let appTag = Font.system(size: 9, weight: .semibold)

    /// 9pt bold — emphasized tag labels
    static let appTagBold = Font.system(size: 9, weight: .bold)

    // -- Chrome / navigation fonts --

    /// 10pt semibold — chip labels, workspace details
    static let appChip = Font.system(size: 10, weight: .semibold)

    /// 11pt semibold — toolbar labels, session titles
    static let appCaption = Font.system(size: 11, weight: .semibold)

    /// 12pt regular — workspace names, context labels
    static let appLabel = Font.system(size: 12)

    // -- Settings / section headers --

    /// 16pt medium — settings section headers
    static let appSectionHeader = Font.system(size: 16, weight: .medium)

    /// 18pt regular — emoji picker display
    static let appEmoji = Font.system(size: 18)

    /// 8pt regular — emoji caption
    static let appEmojiCaption = Font.system(size: 8)

    // -- Display / hero fonts --

    /// 48pt regular — hero display (onboarding)
    static let appHero = Font.system(size: 48)
}
