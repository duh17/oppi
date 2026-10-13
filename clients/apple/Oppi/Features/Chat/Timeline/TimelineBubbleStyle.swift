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
/// style; ChatView picks it from the session and the Compact Turns layout
/// (`ChatTimelineChromeStyle.for`).
///
/// This is the one owner of chrome that differs between the styles: rows
/// read their surface (shape, padding, margins) and fill from here and draw
/// the surface with `TimelineChromeSurfaceView`.
enum ChatTimelineChromeStyle: Equatable {
    /// Coding transcript: full-width user card and unboxed assistant prose.
    case standard
    /// Messaging layout: trailing user bubble, assistant card without the
    /// avatar, and work folded into a hugging "Worked · N steps" pill.
    case conversation

    /// Durable sessions open in the conversation layout while this device
    /// has the Durable Sessions experiment on, whatever Compact Turns says.
    /// Other sessions follow the Compact Turns layout; `compactTurnsLayout`
    /// is nil when Compact Turns is off or does not apply to this window.
    static func `for`(
        engine: SessionEngine?,
        durableExperimentEnabled: Bool,
        compactTurnsLayout: AppPreferences.ChatDisplay.Layout?
    ) -> Self {
        if durableExperimentEnabled && engine == .durable { return .conversation }
        return compactTurnsLayout == .conversation ? .conversation : .standard
    }

    /// User message: a full-width card, or a trailing bubble no wider than
    /// `userBubbleMaxWidth`.
    var userBubble: TimelineChromeSurface {
        switch self {
        case .standard:
            TimelineChromeSurface(
                shape: .roundedRect(radius: TimelineBubbleStyle.bubbleCornerRadius, curve: .circular),
                padding: NSDirectionalEdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10)
            )
        case .conversation:
            TimelineChromeSurface(
                shape: .roundedRect(radius: Self.conversationCornerRadius, curve: .continuous),
                padding: NSDirectionalEdgeInsets(top: 9, leading: 14, bottom: 9, trailing: 14)
            )
        }
    }

    /// Assistant reply. Standard prose is full width with room for the
    /// hanging avatar; the conversation card also spans the row. The
    /// trailing, tinted user bubble already says who is speaking, and a
    /// trailing gutter here starved tables and code blocks on phones.
    var assistantBubble: TimelineChromeSurface {
        switch self {
        case .standard:
            TimelineChromeSurface(
                shape: .roundedRect(radius: TimelineBubbleStyle.bubbleCornerRadius, curve: .circular),
                padding: NSDirectionalEdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 6)
            )
        case .conversation:
            TimelineChromeSurface(
                shape: .roundedRect(radius: Self.conversationCornerRadius, curve: .continuous),
                padding: NSDirectionalEdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14)
            )
        }
    }

    /// Folded work row: a full-width strip, or a leading pill that hugs its
    /// text and sits inside the 44 pt touch row.
    var workLine: TimelineChromeSurface {
        switch self {
        case .standard:
            TimelineChromeSurface(
                shape: .roundedRect(radius: TimelineBubbleStyle.bubbleCornerRadius, curve: .continuous),
                padding: NSDirectionalEdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 14)
            )
        case .conversation:
            TimelineChromeSurface(
                shape: .capsule,
                padding: NSDirectionalEdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12),
                margins: NSDirectionalEdgeInsets(top: 5, leading: 0, bottom: 5, trailing: 0)
            )
        }
    }

    /// Widest a user bubble may be in a row this wide; nil spans the row.
    /// The 620 pt cap keeps wide (iPad, landscape) bubbles readable.
    func userBubbleMaxWidth(rowWidth: CGFloat) -> CGFloat? {
        switch self {
        case .standard: nil
        case .conversation: min(620, (rowWidth * 0.82).rounded(.down))
        }
    }

    /// Conversation cards keep the theme's assistant fill when it has one.
    /// Built-ins leave that clear and get `conversationCardFill`; custom
    /// themes without one lift the card onto `bgHighlight`.
    func assistantFill(
        from palette: ThemePalette,
        themeID: ThemeID = ThemeRuntimeState.currentThemeID()
    ) -> UIColor {
        let themed = TimelineSpeakerChrome.assistantFill(from: palette)
        switch self {
        case .standard: return themed
        case .conversation:
            guard themed == .clear else { return themed }
            return Self.conversationCardFill(for: themeID) ?? UIColor(palette.bgHighlight)
        }
    }

    /// Built-in assistant card, like ChatGPT and Claude: the reply sits on a
    /// quiet surface one small step off `bg` (white paper in Light, barely
    /// lifted in the dark themes) and the user bubble (`userMessageBg`) is the
    /// strongest fill. A `bgHighlight` card read as a second user bubble in
    /// Light and hid inline code, table headers, and diagrams, which all
    /// draw on `bgHighlight`.
    static func conversationCardFill(for themeID: ThemeID) -> UIColor? {
        switch themeID {
        case .light: return TimelineSpeakerChrome.rgb(0xFFFFFF)
        case .dark: return TimelineSpeakerChrome.rgb(0x1F2231)
        case .oled: return TimelineSpeakerChrome.rgb(0x0B0F17)
        case .night: return TimelineSpeakerChrome.rgb(0x161513)
        case .custom: return nil
        }
    }

    /// Work row colors. Standard strips use translucent accent fills to stay
    /// in the tool-row family (`userMessageBg` is opaque in shipped themes,
    /// so matching it read as a second user bubble). The conversation pill
    /// is neutral beside the assistant card; only live work tints it.
    func workLineColors(
        for workLine: QuietTimelineWorkLine,
        isHighlighted: Bool,
        palette: ThemePalette
    ) -> (fill: UIColor, foreground: UIColor, border: UIColor) {
        let accent = UIColor(palette.blue)
        let foreground = workLine.isLive ? accent : UIColor(palette.fgDim)
        switch self {
        case .conversation:
            let fill: UIColor
            if isHighlighted {
                fill = UIColor(palette.fgDim).withAlphaComponent(0.22)
            } else if workLine.isLive {
                fill = accent.withAlphaComponent(0.14)
            } else {
                fill = UIColor(palette.bgHighlight)
            }
            return (fill: fill, foreground: foreground, border: .clear)
        case .standard:
            let fillAlpha: CGFloat
            if isHighlighted {
                fillAlpha = 0.30
            } else if workLine.isLive {
                fillAlpha = 0.16
            } else if workLine.isExpanded {
                fillAlpha = 0.13
            } else {
                fillAlpha = 0.11
            }
            return (
                fill: accent.withAlphaComponent(fillAlpha),
                foreground: foreground,
                border: accent.withAlphaComponent(workLine.isLive ? 0.45 : 0.25)
            )
        }
    }

    private static let conversationCornerRadius: CGFloat = 18
}

/// Corner shape of a timeline chrome surface.
enum TimelineChromeShape: Equatable {
    case roundedRect(radius: CGFloat, curve: CALayerCornerCurve)
    /// Fully round ends; the radius follows the surface's height.
    case capsule
}

/// Shape and spacing of one row surface: the user bubble, the assistant
/// card, or the work strip/pill.
struct TimelineChromeSurface: Equatable {
    let shape: TimelineChromeShape
    /// Content inset inside the surface.
    let padding: NSDirectionalEdgeInsets
    /// Space between the surface and the row's edges.
    var margins: NSDirectionalEdgeInsets = .zero
}

/// Pins a view inside its container on four edges; `inset(by:)` applies a
/// surface's padding or margins to them.
@MainActor
struct TimelineEdgeConstraints {
    let top: NSLayoutConstraint
    let leading: NSLayoutConstraint
    let bottom: NSLayoutConstraint
    let trailing: NSLayoutConstraint

    init(pinning view: UIView, to container: UIView) {
        top = view.topAnchor.constraint(equalTo: container.topAnchor)
        leading = view.leadingAnchor.constraint(equalTo: container.leadingAnchor)
        bottom = view.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        trailing = view.trailingAnchor.constraint(equalTo: container.trailingAnchor)
    }

    var all: [NSLayoutConstraint] { [top, leading, bottom, trailing] }

    func inset(by insets: NSDirectionalEdgeInsets) {
        top.constant = insets.top
        leading.constant = insets.leading
        bottom.constant = -insets.bottom
        trailing.constant = -insets.trailing
    }
}

/// Draws a `TimelineChromeShape`. The view resolves its own corner radius when
/// the shape or its size changes, so rows never write `layer.cornerRadius`.
/// A capsule depends on the surface's height; resolving it anywhere else left
/// it square whenever a row was reconfigured without a new layout pass.
final class TimelineChromeSurfaceView: UIView {
    var shape: TimelineChromeShape = .roundedRect(radius: 0, curve: .circular) {
        didSet {
            guard shape != oldValue else { return }
            applyShape()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyShape()
    }

    private func applyShape() {
        switch shape {
        case let .roundedRect(radius, curve):
            layer.cornerRadius = radius
            layer.cornerCurve = curve
        case .capsule:
            layer.cornerRadius = min(bounds.width, bounds.height) / 2
            layer.cornerCurve = .circular
        }
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

    fileprivate static func rgb(_ hex: UInt32) -> UIColor {
        UIColor(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
