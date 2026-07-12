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

extension ShapeStyle where Self == Color {
    static var themeBg: Color { Color.themeBg }
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

    static var themeScrim: Color { Color.themeScrim }
    static var themeOnBlue: Color { Color.themeOnBlue }
    // periphery:ignore - used by ChatSubviews through SwiftUI contextual static member lookup
    static var themeOnGreen: Color { Color.themeOnGreen }

    // Semantic
    static var themeSyntaxKeyword: Color { Color.themeSyntaxKeyword }
    static var themeDiffAdded: Color { Color.themeDiffAdded }
    static var themeDiffRemoved: Color { Color.themeDiffRemoved }
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

extension View {
    /// Apply a semantic themed surface behind this view, clipped to `shape`:
    /// role-resolved fill, glass blur pairing for translucent roles, and the
    /// role's hairline stroke. This is the sanctioned way to put a themed
    /// panel fill behind content — roles resolve opacity in one place.
    @ViewBuilder
    func themedSurface<S: Shape>(_ role: ThemeSurfaceRole, in shape: S) -> some View {
        let style = ThemeSurfaceStyle.resolve(role)
        if style.wantsGlassBlur {
            background(style.fill, in: shape)
                .glassEffect(.regular, in: shape)
                .overlay { themedSurfaceStroke(style, in: shape) }
        } else {
            background(style.fill, in: shape)
                .overlay { themedSurfaceStroke(style, in: shape) }
        }
    }
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

    /// Use for freeform text entry surfaces that need stable contrast and a
    /// consistent inset card shape across editors and multiline inputs.
    func themedTextInputCard(
        background: Color = .themeBgDark,
        cornerRadius: CGFloat = 14,
        contentPadding: CGFloat = 10,
        strokeOpacity: Double = 0.18
    ) -> some View {
        self
            .padding(contentPadding)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.themeComment.opacity(strokeOpacity), lineWidth: 1)
            )
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
        guard let luminance = relativeLuminance(of: fill) else {
            return .themeFg
        }
        return luminance > 0.55 ? .themeBgDark : .themeFg
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
