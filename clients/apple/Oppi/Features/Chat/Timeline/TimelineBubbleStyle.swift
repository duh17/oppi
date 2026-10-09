import SwiftUI
import UIKit

/// Named visual constants for timeline row bubble/chip styling.
///
/// Centralises magic numbers scattered across row content views so
/// visual tweaks propagate everywhere in one change.
enum TimelineBubbleStyle {
    // MARK: - Corner Radii

    /// Standard message bubble (assistant, user, thinking, compaction).
    static let bubbleCornerRadius: CGFloat = 10

    /// Compact chip rows (audio clip).
    static let chipCornerRadius: CGFloat = 8

    /// Inset elements inside a bubble (user image thumbnails).
    static let thumbnailCornerRadius: CGFloat = 8

    // MARK: - Background Alpha

    /// Subtle bubble tint shared across assistant (purple) and thinking-done
    /// (comment) rows.
    static let subtleBgAlpha: CGFloat = 0.08

    /// Lighter variant used for thinking-streaming bubbles.
    static let streamingBgAlpha: CGFloat = 0.06

    /// Strong tint for error rows.
    static let errorBgAlpha: CGFloat = 0.18

    /// User thumbnail border alpha (over comment color).
    static let thumbnailBorderAlpha: CGFloat = 0.3
}

/// Row chrome for one chat timeline. Every row in a timeline uses the same
/// style; ChatView picks it from the session (`ChatTimelineChromeStyle.for`).
enum ChatTimelineChromeStyle: Equatable {
    /// Coding transcript: full-width user card and unboxed assistant prose.
    case standard
    /// Messaging layout for durable sessions: trailing user bubble, assistant
    /// card without the avatar, and work folded into a hugging
    /// "Worked · N steps" pill.
    case conversation

    /// Durable sessions open in the conversation layout while this device
    /// has the Durable Sessions experiment on. Classic sessions never do.
    static func `for`(engine: SessionEngine?, durableExperimentEnabled: Bool) -> Self {
        durableExperimentEnabled && engine == .durable ? .conversation : .standard
    }
}

/// Geometry for `ChatTimelineChromeStyle.conversation`.
enum ConversationBubbleChrome {
    static let cornerRadius: CGFloat = 18
    /// User bubbles and assistant cards never span the full row, so the
    /// trailing/leading gutter says who is speaking without a caption.
    static let maxWidthFraction: CGFloat = 0.82
    /// Cap for wide (iPad, landscape) rows so a bubble stays readable.
    static let maxWidth: CGFloat = 620
    static let userHorizontalPadding: CGFloat = 14
    static let userVerticalPadding: CGFloat = 9
    static let assistantHorizontalPadding: CGFloat = 14
    static let assistantVerticalPadding: CGFloat = 10
    /// Space the assistant card leaves on its trailing edge.
    static let assistantTrailingGutter: CGFloat = 28

    static func maxBubbleWidth(rowWidth: CGFloat) -> CGFloat {
        min(maxWidth, (rowWidth * maxWidthFraction).rounded(.down))
    }

    /// Assistant cards keep the theme's assistant fill when it has one;
    /// built-ins leave it clear, so the card lifts onto `bgHighlight`.
    static func assistantCardFill(from palette: ThemePalette) -> UIColor {
        let themed = TimelineSpeakerChrome.assistantFill(from: palette)
        return themed == .clear ? UIColor(palette.bgHighlight) : themed
    }
}

/// Speaker chrome for user vs assistant timeline rows.
///
/// User rows are the only elevated card: `userMessageBg` fill, plus a leading
/// strip only when a custom theme sets `userMessageAccent`. Assistant rows
/// stay full width and recede (clear fill in built-ins). Increase Contrast and
/// Differentiate Without Color are resolved at the timeline controller and
/// passed into each user row configuration.
enum TimelineSpeakerChrome {
    static let accentBarWidth: CGFloat = 3
    static let increasedContrastBorderWidth: CGFloat = 1.5
    /// Extra space above a user row so each exchange groups (8 pt layout gap
    /// + 8 pt = 16 pt before a user row). Applied as the user cell's own top
    /// margin so cached-height layout and scroll anchoring stay unchanged.
    static let userTurnSpacingAbove: CGFloat = 8
    /// Spacing inside the user bubble stack. UIStackView applies this only
    /// between visible arranged subviews, so a Differentiate Without Color
    /// caption adds it when text, badges, or path pills are also showing.
    static let userBubbleContentSpacing: CGFloat = 6

    @MainActor
    static func increasedContrast(traitCollection: UITraitCollection) -> Bool {
        if UIAccessibility.isDarkerSystemColorsEnabled { return true }
        return traitCollection.accessibilityContrast == .high
    }

    @MainActor
    static func differentiateWithoutColor() -> Bool {
        UIAccessibility.shouldDifferentiateWithoutColor
    }

    static func userFill(
        from palette: ThemePalette,
        increasedContrast: Bool,
        themeID: ThemeID = ThemeRuntimeState.currentThemeID()
    ) -> UIColor {
        if increasedContrast, let stronger = increasedContrastFill(for: themeID) {
            return stronger
        }
        return UIColor(palette.userMessageBg)
    }

    /// Nil unless the theme opts in; built-ins draw no strip.
    static func userAccent(from palette: ThemePalette) -> UIColor? {
        palette.userMessageAccent.map { UIColor($0) }
    }

    /// Increase Contrast outlines the user card in the theme's accent, or in
    /// the card's own text color, which already clears 4.5:1 on the fill.
    static func increasedContrastBorder(from palette: ThemePalette) -> UIColor {
        userAccent(from: palette) ?? UIColor(palette.userMessageText)
    }

    static func assistantFill(from palette: ThemePalette) -> UIColor {
        let color = UIColor(palette.assistantMessageBg)
        return resolvedAlpha(of: color) < 0.02 ? .clear : color
    }

    /// Stronger user fills when Increase Contrast is on. Built-ins only;
    /// custom themes keep their `userMessageBg` and gain the border.
    static func increasedContrastFill(for themeID: ThemeID) -> UIColor? {
        switch themeID {
        case .dark: return rgb(0x4A5680)
        case .oled: return rgb(0x2A3850)
        case .night: return rgb(0x44382A)
        case .light: return rgb(0xB2AEA5)
        case .custom: return nil
        }
    }

    static func resolvedAlpha(
        of color: UIColor,
        traitCollection: UITraitCollection = UITraitCollection(userInterfaceStyle: .dark)
    ) -> CGFloat {
        color.resolvedColor(with: traitCollection).cgColor.alpha
    }

    private static func rgb(_ hex: UInt32) -> UIColor {
        UIColor(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
