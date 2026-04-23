import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Static theme color accessors resolved from the active runtime theme.
///
/// All views use `.theme*` accessors instead of hardcoded colors.
/// Values change dynamically when the user switches themes.
extension Color {
    private static var palette: ThemePalette {
        ThemeRuntimeState.currentPalette()
    }

    static var themeBg: Color { palette.bg }
    static var themeBgDark: Color { palette.bgDark }
    static var themeBgHighlight: Color { palette.bgHighlight }

    static var themeFg: Color { palette.fg }
    static var themeFgDim: Color { palette.fgDim }
    static var themeComment: Color { palette.comment }

    static var themeBlue: Color { palette.blue }
    static var themeCyan: Color { palette.cyan }
    static var themeGreen: Color { palette.green }
    static var themeOrange: Color { palette.orange }
    static var themePurple: Color { palette.purple }
    static var themeRed: Color { palette.red }
    static var themeYellow: Color { palette.yellow }

    // MARK: - Semantic UI Helpers

    static var themeChipSubtleBg: Color { palette.comment.opacity(0.16) }
    static var themeScrim: Color { palette.bgDark.opacity(0.82) }
    static var themeOnBlue: Color { ThemeColorContrast.foreground(for: palette.blue) }
    static var themeOnGreen: Color { ThemeColorContrast.foreground(for: palette.green) }
    static var themeOnOrange: Color { ThemeColorContrast.foreground(for: palette.orange) }
    static var themeOnPurple: Color { ThemeColorContrast.foreground(for: palette.purple) }
    static var themeOnRed: Color { ThemeColorContrast.foreground(for: palette.red) }

    // MARK: - User Message

    static var themeUserMessageBg: Color { palette.userMessageBg }
    static var themeUserMessageText: Color { palette.userMessageText }

    // MARK: - Tool State

    static var themeToolPendingBg: Color { palette.toolPendingBg }
    static var themeToolSuccessBg: Color { palette.toolSuccessBg }
    static var themeToolErrorBg: Color { palette.toolErrorBg }
    static var themeToolTitle: Color { palette.toolTitle }
    static var themeToolOutput: Color { palette.toolOutput }

    // MARK: - Semantic Syntax

    static var themeSyntaxComment: Color { palette.syntaxComment }
    static var themeSyntaxKeyword: Color { palette.syntaxKeyword }
    static var themeSyntaxFunction: Color { palette.syntaxFunction }
    static var themeSyntaxVariable: Color { palette.syntaxVariable }
    static var themeSyntaxString: Color { palette.syntaxString }
    static var themeSyntaxNumber: Color { palette.syntaxNumber }
    static var themeSyntaxType: Color { palette.syntaxType }
    static var themeSyntaxOperator: Color { palette.syntaxOperator }
    static var themeSyntaxPunctuation: Color { palette.syntaxPunctuation }

    // MARK: - Semantic Markdown

    static var themeMdHeading: Color { palette.mdHeading }
    static var themeMdLink: Color { palette.mdLink }
    static var themeMdLinkUrl: Color { palette.mdLinkUrl }
    static var themeMdCode: Color { palette.mdCode }
    static var themeMdCodeBlock: Color { palette.mdCodeBlock }
    static var themeMdCodeBlockBorder: Color { palette.mdCodeBlockBorder }
    static var themeMdQuote: Color { palette.mdQuote }
    static var themeMdQuoteBorder: Color { palette.mdQuoteBorder }
    static var themeMdHr: Color { palette.mdHr }
    static var themeMdListBullet: Color { palette.mdListBullet }

    // MARK: - Semantic Diff

    static var themeDiffAdded: Color { palette.toolDiffAdded }
    static var themeDiffRemoved: Color { palette.toolDiffRemoved }
    static var themeDiffContext: Color { palette.toolDiffContext }
}

extension ShapeStyle where Self == Color {
    static var themeBg: Color { Color.themeBg }
    static var themeBgDark: Color { Color.themeBgDark }
    static var themeBgHighlight: Color { Color.themeBgHighlight }
    static var themeFg: Color { Color.themeFg }
    static var themeFgDim: Color { Color.themeFgDim }
    static var themeComment: Color { Color.themeComment }
    static var themeBlue: Color { Color.themeBlue }
    static var themeCyan: Color { Color.themeCyan }
    static var themeGreen: Color { Color.themeGreen }
    static var themeOrange: Color { Color.themeOrange }
    static var themePurple: Color { Color.themePurple }
    static var themeRed: Color { Color.themeRed }
    static var themeYellow: Color { Color.themeYellow }

    static var themeChipSubtleBg: Color { Color.themeChipSubtleBg }
    static var themeScrim: Color { Color.themeScrim }
    static var themeOnBlue: Color { Color.themeOnBlue }
    static var themeOnGreen: Color { Color.themeOnGreen }
    static var themeOnOrange: Color { Color.themeOnOrange }
    static var themeOnPurple: Color { Color.themeOnPurple }
    static var themeOnRed: Color { Color.themeOnRed }

    // Semantic
    static var themeSyntaxComment: Color { Color.themeSyntaxComment }
    static var themeSyntaxKeyword: Color { Color.themeSyntaxKeyword }
    static var themeSyntaxFunction: Color { Color.themeSyntaxFunction }
    static var themeSyntaxVariable: Color { Color.themeSyntaxVariable }
    static var themeSyntaxString: Color { Color.themeSyntaxString }
    static var themeSyntaxNumber: Color { Color.themeSyntaxNumber }
    static var themeSyntaxType: Color { Color.themeSyntaxType }
    static var themeSyntaxOperator: Color { Color.themeSyntaxOperator }
    static var themeSyntaxPunctuation: Color { Color.themeSyntaxPunctuation }
    static var themeMdHeading: Color { Color.themeMdHeading }
    static var themeMdLink: Color { Color.themeMdLink }
    static var themeMdLinkUrl: Color { Color.themeMdLinkUrl }
    static var themeMdCode: Color { Color.themeMdCode }
    static var themeMdCodeBlock: Color { Color.themeMdCodeBlock }
    static var themeMdCodeBlockBorder: Color { Color.themeMdCodeBlockBorder }
    static var themeMdQuote: Color { Color.themeMdQuote }
    static var themeMdQuoteBorder: Color { Color.themeMdQuoteBorder }
    static var themeMdHr: Color { Color.themeMdHr }
    static var themeMdListBullet: Color { Color.themeMdListBullet }
    static var themeDiffAdded: Color { Color.themeDiffAdded }
    static var themeDiffRemoved: Color { Color.themeDiffRemoved }
    static var themeDiffContext: Color { Color.themeDiffContext }
}

// MARK: - Themed Surface Modifiers

extension View {
    /// Use for List/Form screens. Replaces native list chrome with theme background.
    /// Section "cards" keep their system appearance (matches Dark/Light perfectly,
    /// near-match for Night/custom).
    func themedListSurface() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(Color.themeBg.ignoresSafeArea())
    }

    /// Use for custom ScrollView/VStack screens (dashboards, charts).
    func themedScrollSurface() -> some View {
        self
            .background(Color.themeBg.ignoresSafeArea())
    }
}

// MARK: - Theme Contrast Helpers

enum ThemeColorContrast {
    static func foreground(for fill: Color) -> Color {
        guard let luminance = relativeLuminance(of: fill) else {
            return .themeFg
        }
        return luminance > 0.55 ? .themeBgDark : .themeFg
    }

    private static func relativeLuminance(of color: Color) -> CGFloat? {
        guard let (red, green, blue) = rgbComponents(for: color) else {
            return nil
        }
        return 0.2126 * linearize(red) + 0.7152 * linearize(green) + 0.0722 * linearize(blue)
    }

    private static func linearize(_ component: CGFloat) -> CGFloat {
        if component <= 0.03928 {
            return component / 12.92
        }
        return pow((component + 0.055) / 1.055, 2.4)
    }

    private static func rgbComponents(for color: Color) -> (CGFloat, CGFloat, CGFloat)? {
        #if canImport(UIKit)
        let uiColor = UIColor(color)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return nil
        }
        return (red, green, blue)
        #elseif canImport(AppKit)
        let nsColor = NSColor(color)
        guard let converted = nsColor.usingColorSpace(.sRGB) else {
            return nil
        }
        return (converted.redComponent, converted.greenComponent, converted.blueComponent)
        #else
        return nil
        #endif
    }
}

// MARK: - Motion Helpers

enum ThemeMotion {
    static func animation(_ animation: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }

    static func standard(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .default
    }

    static func easeIn(duration: Double, reduceMotion: Bool) -> Animation? {
        animation(.easeIn(duration: duration), reduceMotion: reduceMotion)
    }

    static func easeInOut(duration: Double, reduceMotion: Bool) -> Animation? {
        animation(.easeInOut(duration: duration), reduceMotion: reduceMotion)
    }

    static func pulse(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
    }

    static func move(edge: Edge, reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: edge).combined(with: .opacity)
    }

    static func scaleFade(
        scale: CGFloat = 0.96,
        anchor: UnitPoint = .center,
        reduceMotion: Bool
    ) -> AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: scale, anchor: anchor))
    }

    static func directionalPage(forward: Bool, reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .move(edge: forward ? .trailing : .leading),
            removal: .move(edge: forward ? .leading : .trailing)
        )
    }
}
