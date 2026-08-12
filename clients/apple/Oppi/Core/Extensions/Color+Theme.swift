import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Snapshot theme colors for APIs that require a concrete `Color` or bridge
/// into UIKit/AppKit. SwiftUI foreground/fill/stroke call sites should use the
/// contextual `.theme*` shorthand backed by `ThemeShapeStyle` below; explicit
/// `Color.theme*` values do not themselves register an environment dependency.
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

    static var themeScrim: Color { palette.bgDark.opacity(0.82) }

    /// Half scrim that dims content behind an expanded overlay bar (context
    /// bar) without fully hiding it. Pairs with tap-to-collapse.
    static var themeDimScrim: Color { palette.bg.opacity(0.5) }

    /// Recessed fill for text fields, status banners, and icon wells inset
    /// into an elevated panel. Reads as a subtle well against the panel fill.
    static var themeRecessedInset: Color { palette.bg.opacity(0.30) }

    /// Fill for a semantic surface role where only a `Color` fits the API
    /// (footer `ignoresSafeArea` backgrounds, `presentationBackground`).
    /// Prefer `View.themedSurface(_:in:)` for shaped panels.
    static func themeSurfaceFill(_ role: ThemeSurfaceRole) -> Color {
        ThemeSurfaceStyle.resolve(role).fill
    }

    /// Themed surface fill math: opacity keeps dark palettes glassy and raises
    /// light palettes toward opaque so content behind the panel does not ghost
    /// through. File-private so UI code picks a `ThemeSurfaceRole` instead of
    /// ad-hoc opacity values — `ThemeSurfaceStyle.resolve` is the only caller.
    fileprivate static func themeSurface(
        darkOpacity: Double,
        lightOpacity: Double = 0.98,
        palette: ThemePalette
    ) -> Color {
        palette.bgDark.opacity(
            ThemeColorContrast.adaptiveSurfaceOpacity(
                for: palette.bgDark,
                darkOpacity: darkOpacity,
                lightOpacity: lightOpacity
            )
        )
    }

    static var themeOnBlue: Color { ThemeColorContrast.foreground(for: palette.blue) }
    static var themeOnGreen: Color { ThemeColorContrast.foreground(for: palette.green) }

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

    // periphery:ignore - used by OrgFoldableView; Periphery misses this Color extension accessor
    static var themeMdHeading: Color { palette.mdHeading }

    // MARK: - Semantic Diff

    static var themeDiffAdded: Color { palette.toolDiffAdded }
    static var themeDiffRemoved: Color { palette.toolDiffRemoved }
    // periphery:ignore - used by ToolRowTextRenderer via UIColor(Color.themeDiffContext)
    static var themeDiffContext: Color { palette.toolDiffContext }
}

/// Environment-resolved theme style for SwiftUI foregrounds, fills, strokes,
/// and style-based backgrounds. Unlike `Color.theme*`, this registers a real
/// `EnvironmentValues.theme` dependency, so persistent List/LazyVStack cells
/// repaint when the active theme changes instead of retaining captured colors.
struct ThemeShapeStyle: ShapeStyle {
    enum Role: Sendable {
        case background
        case backgroundDark
        case backgroundHighlight
        case foreground
        case foregroundDim
        case comment
        case blue
        case cyan
        case green
        case orange
        case purple
        case red
        case yellow
        case scrim
        case onBlue
        case onGreen
        case syntaxComment
        case syntaxKeyword
        case syntaxFunction
        case syntaxVariable
        case syntaxString
        case syntaxNumber
        case syntaxType
        case syntaxOperator
        case syntaxPunctuation
        case markdownHeading
        case diffAdded
        case diffRemoved
        case diffContext
    }

    let role: Role

    func resolve(in environment: EnvironmentValues) -> some ShapeStyle {
        color(in: environment)
    }

    func color(in environment: EnvironmentValues) -> Color {
        let theme = environment.theme
        return switch role {
        case .background: theme.bg.primary
        case .backgroundDark: theme.bg.secondary
        case .backgroundHighlight: theme.bg.highlight
        case .foreground: theme.text.primary
        case .foregroundDim: theme.text.secondary
        case .comment: theme.text.tertiary
        case .blue: theme.accent.blue
        case .cyan: theme.accent.cyan
        case .green: theme.accent.green
        case .orange: theme.accent.orange
        case .purple: theme.accent.purple
        case .red: theme.accent.red
        case .yellow: theme.accent.yellow
        case .scrim: theme.bg.secondary.opacity(0.82)
        case .onBlue:
            ThemeColorContrast.foreground(
                for: theme.accent.blue,
                highLuminanceForeground: theme.bg.secondary,
                lowLuminanceForeground: theme.text.primary
            )
        case .onGreen:
            ThemeColorContrast.foreground(
                for: theme.accent.green,
                highLuminanceForeground: theme.bg.secondary,
                lowLuminanceForeground: theme.text.primary
            )
        case .syntaxComment: theme.syntax.comment
        case .syntaxKeyword: theme.syntax.keyword
        case .syntaxFunction: theme.syntax.function
        case .syntaxVariable: theme.syntax.variable
        case .syntaxString: theme.syntax.string
        case .syntaxNumber: theme.syntax.number
        case .syntaxType: theme.syntax.type
        case .syntaxOperator: theme.syntax.operator
        case .syntaxPunctuation: theme.syntax.punctuation
        case .markdownHeading: theme.markdown.heading
        case .diffAdded: theme.diff.addedAccent
        case .diffRemoved: theme.diff.removedAccent
        case .diffContext: theme.diff.contextFg
        }
    }
}

extension ShapeStyle where Self == ThemeShapeStyle {
    static var themeBg: ThemeShapeStyle { ThemeShapeStyle(role: .background) }
    static var themeBgDark: ThemeShapeStyle { ThemeShapeStyle(role: .backgroundDark) }
    static var themeBgHighlight: ThemeShapeStyle { ThemeShapeStyle(role: .backgroundHighlight) }
    static var themeFg: ThemeShapeStyle { ThemeShapeStyle(role: .foreground) }
    static var themeFgDim: ThemeShapeStyle { ThemeShapeStyle(role: .foregroundDim) }
    static var themeComment: ThemeShapeStyle { ThemeShapeStyle(role: .comment) }
    static var themeBlue: ThemeShapeStyle { ThemeShapeStyle(role: .blue) }
    static var themeCyan: ThemeShapeStyle { ThemeShapeStyle(role: .cyan) }
    static var themeGreen: ThemeShapeStyle { ThemeShapeStyle(role: .green) }
    static var themeOrange: ThemeShapeStyle { ThemeShapeStyle(role: .orange) }
    static var themePurple: ThemeShapeStyle { ThemeShapeStyle(role: .purple) }
    static var themeRed: ThemeShapeStyle { ThemeShapeStyle(role: .red) }
    static var themeYellow: ThemeShapeStyle { ThemeShapeStyle(role: .yellow) }

    static var themeScrim: ThemeShapeStyle { ThemeShapeStyle(role: .scrim) }
    static var themeOnBlue: ThemeShapeStyle { ThemeShapeStyle(role: .onBlue) }
    // periphery:ignore - used by ChatSubviews through SwiftUI contextual static member lookup
    static var themeOnGreen: ThemeShapeStyle { ThemeShapeStyle(role: .onGreen) }

    static var themeSyntaxComment: ThemeShapeStyle { ThemeShapeStyle(role: .syntaxComment) }
    static var themeSyntaxKeyword: ThemeShapeStyle { ThemeShapeStyle(role: .syntaxKeyword) }
    static var themeSyntaxFunction: ThemeShapeStyle { ThemeShapeStyle(role: .syntaxFunction) }
    static var themeSyntaxVariable: ThemeShapeStyle { ThemeShapeStyle(role: .syntaxVariable) }
    static var themeSyntaxString: ThemeShapeStyle { ThemeShapeStyle(role: .syntaxString) }
    static var themeSyntaxNumber: ThemeShapeStyle { ThemeShapeStyle(role: .syntaxNumber) }
    static var themeSyntaxType: ThemeShapeStyle { ThemeShapeStyle(role: .syntaxType) }
    static var themeSyntaxOperator: ThemeShapeStyle { ThemeShapeStyle(role: .syntaxOperator) }
    static var themeSyntaxPunctuation: ThemeShapeStyle { ThemeShapeStyle(role: .syntaxPunctuation) }
    static var themeMdHeading: ThemeShapeStyle { ThemeShapeStyle(role: .markdownHeading) }
    static var themeDiffAdded: ThemeShapeStyle { ThemeShapeStyle(role: .diffAdded) }
    static var themeDiffRemoved: ThemeShapeStyle { ThemeShapeStyle(role: .diffRemoved) }
    static var themeDiffContext: ThemeShapeStyle { ThemeShapeStyle(role: .diffContext) }
}

// MARK: - Themed Surface Roles

/// Semantic roles for themed panels that float over app content.
///
/// Roles replace ad-hoc `darkOpacity` values at call sites. The compositing
/// contract (checked by ElevatedSurfaceOpacityTests):
/// - Translucent roles keep dark palettes glassy, so they REQUIRE a glass blur
///   behind the fill (`wantsGlassBlur`); without blur, timeline text ghosts
///   through a low-opacity fill.
/// - Blur-free roles resolve near-opaque regardless of fill luminance.
/// - Light palettes always resolve near-opaque via
///   `ThemeColorContrast.adaptiveSurfaceOpacity`.
enum ThemeSurfaceRole: CaseIterable {
    /// Panels floating over the chat timeline: extension surfaces, message
    /// queue, floating busy/status panels.
    case elevatedPanel
    /// Small floating controls over full-bleed content: full-screen viewer
    /// buttons, the file tree glass panel, share capsules, tip banners.
    case floatingControl
    /// Cards and bars over scrolling content with no blur available: expanded
    /// tool bodies, context bar capsules, pinned footers.
    case opaqueCard
    /// System-presented popovers and sheets that replace the default material.
    case popover
}

/// Resolved chrome for a `ThemeSurfaceRole`: fill, optional hairline stroke,
/// and whether the fill must pair with a glass blur. SwiftUI call sites use
/// `View.themedSurface(_:in:)`; UIKit paths consume `UIColor(style.fill)`.
struct ThemeSurfaceStyle {
    let fill: Color
    let stroke: Color?
    let strokeLineWidth: CGFloat
    let wantsGlassBlur: Bool

    /// The single place where per-role surface opacity is chosen.
    static func resolve(
        _ role: ThemeSurfaceRole,
        palette: ThemePalette = ThemeRuntimeState.currentPalette()
    ) -> ThemeSurfaceStyle {
        switch role {
        case .elevatedPanel:
            // 0.78 is the established elevated-glass translucency on dark
            // palettes; it is safe only because the role pairs with blur.
            return ThemeSurfaceStyle(
                fill: .themeSurface(darkOpacity: 0.78, palette: palette),
                stroke: palette.fg.opacity(0.12),
                strokeLineWidth: 0.5,
                wantsGlassBlur: true
            )
        case .floatingControl:
            return ThemeSurfaceStyle(
                fill: .themeSurface(darkOpacity: 0.64, palette: palette),
                stroke: palette.fg.opacity(0.10),
                strokeLineWidth: 1,
                wantsGlassBlur: true
            )
        case .opaqueCard:
            return ThemeSurfaceStyle(
                fill: .themeSurface(darkOpacity: 0.92, palette: palette),
                stroke: palette.comment.opacity(0.22),
                strokeLineWidth: 1,
                wantsGlassBlur: false
            )
        case .popover:
            return ThemeSurfaceStyle(
                fill: .themeSurface(darkOpacity: 0.96, palette: palette),
                stroke: nil,
                strokeLineWidth: 0,
                wantsGlassBlur: false
            )
        }
    }
}

@ViewBuilder
private func themedSurfaceStroke<S: Shape>(_ style: ThemeSurfaceStyle, in shape: S) -> some View {
    if let stroke = style.stroke {
        shape.stroke(stroke, lineWidth: style.strokeLineWidth)
    }
}

// MARK: - Themed Surface Modifiers

private struct ThemedSurfaceModifier<S: Shape>: ViewModifier {
    @Environment(\.themeID) private var themeID

    let role: ThemeSurfaceRole
    let shape: S

    @ViewBuilder
    func body(content: Content) -> some View {
        let style = ThemeSurfaceStyle.resolve(role, palette: themeID.palette)
        if style.wantsGlassBlur {
            content
                .background(style.fill, in: shape)
                .glassEffect(.regular, in: shape)
                .overlay { themedSurfaceStroke(style, in: shape) }
        } else {
            content
                .background(style.fill, in: shape)
                .overlay { themedSurfaceStroke(style, in: shape) }
        }
    }
}

private struct ThemedListRowBackgroundModifier: ViewModifier {
    // Keep the list-row modifier tied to the live environment. The ShapeStyle
    // below resolves the actual fill when each mounted row is rendered.
    @Environment(\.themeID) private var themeID

    func body(content: Content) -> some View {
        let _ = themeID
        return content
            .listRowBackground(Rectangle().fill(.themeBg))
    }
}

private struct ThemedListSurfaceModifier: ViewModifier {
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(theme.bg.primary.ignoresSafeArea())
    }
}

private struct ThemedScrollSurfaceModifier: ViewModifier {
    @Environment(\.themeID) private var themeID

    func body(content: Content) -> some View {
        let _ = themeID
        return content.background {
            Rectangle()
                .fill(.themeBg)
                .ignoresSafeArea()
        }
    }
}

private struct ThemedTextInputCardModifier: ViewModifier {
    @Environment(\.theme) private var theme

    let backgroundOverride: Color?
    let cornerRadius: CGFloat
    let contentPadding: CGFloat
    let strokeOpacity: Double

    func body(content: Content) -> some View {
        content
            .padding(contentPadding)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(backgroundOverride ?? theme.bg.secondary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(theme.text.tertiary.opacity(strokeOpacity), lineWidth: 1)
            )
    }
}

extension View {
    /// Apply a semantic themed surface behind this view, clipped to `shape`:
    /// role-resolved fill, glass blur pairing for translucent roles, and the
    /// role's hairline stroke. This is the sanctioned way to put a themed
    /// panel fill behind content — roles resolve opacity in one place.
    func themedSurface<S: Shape>(_ role: ThemeSurfaceRole, in shape: S) -> some View {
        modifier(ThemedSurfaceModifier(role: role, shape: shape))
    }

    /// Apply the live theme to a List row or grouped Section instead of
    /// allowing the system white/card fill to leak into a themed surface.
    func themedListRowBackground() -> some View {
        modifier(ThemedListRowBackgroundModifier())
    }

    /// Use for List/Form screens. Replaces native list chrome with theme background.
    /// Section "cards" keep their system appearance (matches Dark/Light perfectly,
    /// near-match for Night/custom).
    func themedListSurface() -> some View {
        modifier(ThemedListSurfaceModifier())
    }

    /// Use for custom ScrollView/VStack screens (dashboards, charts).
    func themedScrollSurface() -> some View {
        modifier(ThemedScrollSurfaceModifier())
    }

    /// Use for freeform text entry surfaces that need stable contrast and a
    /// consistent inset card shape across editors and multiline inputs.
    func themedTextInputCard(
        background: Color? = nil,
        cornerRadius: CGFloat = 14,
        contentPadding: CGFloat = 10,
        strokeOpacity: Double = 0.18
    ) -> some View {
        modifier(ThemedTextInputCardModifier(
            backgroundOverride: background,
            cornerRadius: cornerRadius,
            contentPadding: contentPadding,
            strokeOpacity: strokeOpacity
        ))
    }

    /// Use for small floating busy/status panels that sit above app content.
    /// Sugar for the `.elevatedPanel` surface role.
    func themedFloatingPanel(cornerRadius: CGFloat = 12) -> some View {
        themedSurface(
            .elevatedPanel,
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
    }
}

// MARK: - Theme Contrast Helpers

enum ThemeColorContrast {
    static func foreground(for fill: Color) -> Color {
        foreground(
            for: fill,
            highLuminanceForeground: .themeBgDark,
            lowLuminanceForeground: .themeFg
        )
    }

    static func foreground(
        for fill: Color,
        highLuminanceForeground: Color,
        lowLuminanceForeground: Color
    ) -> Color {
        guard let luminance = relativeLuminance(of: fill) else {
            return lowLuminanceForeground
        }
        return luminance > 0.55 ? highLuminanceForeground : lowLuminanceForeground
    }

    /// Adaptive opacity for themed glass/surface fills. Production code
    /// reaches this only through `ThemeSurfaceStyle.resolve` — this is the one
    /// function that owns themed surface opacity math.
    ///
    /// The `darkOpacity` is the visual baseline for dark palettes. As the fill
    /// luminance increases, the opacity moves toward `lightOpacity`, preventing
    /// low-contrast text or rows behind a light themed panel from bleeding
    /// through while preserving the intended glassiness on dark palettes.
    static func adaptiveSurfaceOpacity(
        for fill: Color,
        darkOpacity: Double,
        lightOpacity: Double = 0.98
    ) -> Double {
        guard let luminance = relativeLuminance(of: fill) else { return darkOpacity }
        let clampedLuminance = min(max(Double(luminance), 0), 1)
        let clampedDarkOpacity = min(max(darkOpacity, 0), 1)
        let clampedLightOpacity = min(max(lightOpacity, 0), 1)
        return clampedDarkOpacity + clampedLuminance * (clampedLightOpacity - clampedDarkOpacity)
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
