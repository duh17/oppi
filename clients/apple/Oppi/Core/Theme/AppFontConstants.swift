import SwiftUI
import UIKit

/// Centralized font constants for the entire app.
///
/// UIKit code uses `AppFont.mono*` / `AppFont.system*` constants.
/// SwiftUI code uses `Font.app*` constants (defined in extension below).
/// Tool-specific code can continue using `ToolFont.*` which delegates here.
///
/// Monospaced fonts are dynamic — rebuilt when the user changes font preferences.
/// System fonts remain static.
enum AppFont {
    // MARK: - Monospaced (dynamic, based on FontPreferences)
    //
    // `nonisolated(unsafe)` because these are written only from @MainActor
    // (rebuild()) and read from @MainActor UI code. UIFont is immutable once
    // created, so a stale read during a font-preference transition is harmless.

    /// 10pt — line numbers, counters, secondary labels
    nonisolated(unsafe) static private(set) var monoSmall = UIFont.monospacedSystemFont(ofSize: 10, weight: .regular)
    nonisolated(unsafe) static private(set) var monoSmallSemibold = UIFont.monospacedSystemFont(ofSize: 10, weight: .semibold)

    /// 11pt — code content, output text, ANSI terminal, language labels
    nonisolated(unsafe) static private(set) var mono = UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    nonisolated(unsafe) static private(set) var monoBold = UIFont.monospacedSystemFont(ofSize: 11, weight: .bold)

    /// 12pt — code blocks, diff content, file paths, section headers
    nonisolated(unsafe) static private(set) var monoMedium = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    nonisolated(unsafe) static private(set) var monoMediumBold = UIFont.monospacedSystemFont(ofSize: 12, weight: .bold)
    nonisolated(unsafe) static private(set) var monoMediumSemibold = UIFont.monospacedSystemFont(ofSize: 12, weight: .semibold)

    /// 15pt — prompt icons, spinner characters
    nonisolated(unsafe) static private(set) var monoLarge = UIFont.monospacedSystemFont(ofSize: 15, weight: .regular)
    nonisolated(unsafe) static private(set) var monoLargeSemibold = UIFont.monospacedSystemFont(ofSize: 15, weight: .semibold)

    /// 17pt — assistant icon
    nonisolated(unsafe) static private(set) var monoXL = UIFont.monospacedSystemFont(ofSize: 17, weight: .semibold)

    /// Message body font — system body by default, or the selected mono font
    /// when `FontPreferences.useMonoForMessages` is enabled.
    nonisolated(unsafe) static private(set) var messageBody: UIFont = .preferredFont(forTextStyle: .body)

    // MARK: - System (UIKit, non-monospaced) — these don't change

    /// 11pt — metadata labels, line counts
    static let systemSmall = UIFont.systemFont(ofSize: 11)

    /// 13pt semibold — toast feedback ("Copied")
    static let systemFeedback = UIFont.systemFont(ofSize: 13, weight: .semibold)

    /// 14pt medium — toast feedback ("Saved")
    static let systemFeedbackMedium = UIFont.systemFont(ofSize: 14, weight: .medium)

    // MARK: - Rebuild

    /// Rebuild all dynamic font constants from current preferences.
    /// Called on startup and when font preferences change.
    @MainActor
    static func rebuild() {
        let family = FontPreferences.codeFont

        monoSmall = family.font(size: 10, weight: .regular)
        monoSmallSemibold = family.font(size: 10, weight: .semibold)

        mono = family.font(size: 11, weight: .regular)
        monoBold = family.font(size: 11, weight: .bold)

        monoMedium = family.font(size: 12, weight: .regular)
        monoMediumBold = family.font(size: 12, weight: .bold)
        monoMediumSemibold = family.font(size: 12, weight: .semibold)

        monoLarge = family.font(size: 15, weight: .regular)
        monoLargeSemibold = family.font(size: 15, weight: .semibold)

        monoXL = family.font(size: 17, weight: .semibold)

        // Message body
        if FontPreferences.useMonoForMessages {
            messageBody = family.font(
                size: UIFont.preferredFont(forTextStyle: .body).pointSize,
                weight: .regular
            )
        } else {
            messageBody = .preferredFont(forTextStyle: .body)
        }
    }
}

// MARK: - SwiftUI Font Constants

extension Font {
    // -- Badge / indicator fonts (tiny, fixed size) --

    /// 7pt bold — unread counts, context badges
    static let appBadgeCount = Font.system(size: 7, weight: .bold)

    /// 7pt semibold rounded — context usage percentage
    static let appBadgeCountRounded = Font.system(size: 7, weight: .semibold, design: .rounded)

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

    /// 10pt regular — secondary detail text
    static let appChipLight = Font.system(size: 10)

    /// 11pt semibold — toolbar labels, session titles
    static let appCaption = Font.system(size: 11, weight: .semibold)

    /// 11pt regular — secondary captions
    static let appCaptionLight = Font.system(size: 11)

    /// 11pt monospaced — raw/code content in SwiftUI views
    static let appCaptionMono = Font.system(size: 11, design: .monospaced)

    /// 12pt regular — workspace names, context labels
    static let appLabel = Font.system(size: 12)

    // -- Action / button fonts --

    /// 14pt medium — settings action labels
    static let appAction = Font.system(size: 14, weight: .medium)

    /// 14pt bold — secondary action buttons
    static let appActionBold = Font.system(size: 14, weight: .bold)

    /// 15pt bold — primary send buttons
    static let appButton = Font.system(size: 15, weight: .bold)

    /// 15pt bold monospaced — workspace home session list
    static let appButtonMono = Font.system(size: 15, weight: .bold)

    // -- Settings / section headers --

    /// 16pt medium — settings section headers
    static let appSectionHeader = Font.system(size: 16, weight: .medium)

    /// 18pt regular — emoji picker display
    static let appEmoji = Font.system(size: 18)

    /// 8pt regular — emoji caption
    static let appEmojiCaption = Font.system(size: 8)

    // -- Display / hero fonts --

    /// 48pt monospaced bold — hero display (empty state)
    static let appHeroMono = Font.system(size: 48, design: .monospaced).weight(.bold)

    /// 48pt regular — hero display (onboarding)
    static let appHero = Font.system(size: 48)
}
