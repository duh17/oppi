import Foundation
#if canImport(UIKit)
import UIKit
#endif

// The theme's UIKit face and the platform-neutral surface and contrast rules.
// Both targets compile this file; it imports no SwiftUI. The Mac's SwiftUI
// face (`Color.theme*`, `ThemeShapeStyle`, the themed-surface modifiers,
// `ThemeMotion`, `\.theme`) lives in `OppiMac/Theme/Theme+SwiftUI.swift`.
//
// Tokens here are `ThemeColor`: `UIColor` on iOS, `Color` on the Mac.

#if canImport(UIKit)
/// UIKit-side theme colors.
///
/// UIKit views read these instead of bridging a framework color at the call
/// site, which is why files that build no SwiftUI view used to import
/// SwiftUI only for a color. They resolve from `ThemeRuntimeState`, so a theme
/// switch repaints SwiftUI and UIKit surfaces together; read them where the
/// view applies its theme (`updateProperties()`, trait changes), not into a
/// one-time constant.
extension UIColor {
    static var themeBg: UIColor { ThemeRuntimeState.currentUIKitPalette().bg }
    static var themeBgDark: UIColor { ThemeRuntimeState.currentUIKitPalette().bgDark }
    static var themeBgHighlight: UIColor { ThemeRuntimeState.currentUIKitPalette().bgHighlight }

    static var themeFg: UIColor { ThemeRuntimeState.currentUIKitPalette().fg }
    static var themeFgDim: UIColor { ThemeRuntimeState.currentUIKitPalette().fgDim }
    static var themeComment: UIColor { ThemeRuntimeState.currentUIKitPalette().comment }

    static var themeBlue: UIColor { ThemeRuntimeState.currentUIKitPalette().blue }
    static var themeCyan: UIColor { ThemeRuntimeState.currentUIKitPalette().cyan }
    static var themeGreen: UIColor { ThemeRuntimeState.currentUIKitPalette().green }
    static var themeOrange: UIColor { ThemeRuntimeState.currentUIKitPalette().orange }
    static var themePurple: UIColor { ThemeRuntimeState.currentUIKitPalette().purple }
    static var themeRed: UIColor { ThemeRuntimeState.currentUIKitPalette().red }
    static var themeYellow: UIColor { ThemeRuntimeState.currentUIKitPalette().yellow }

    static var themeToolSuccessBg: UIColor { ThemeRuntimeState.currentUIKitPalette().toolSuccessBg }
    static var themeToolTitle: UIColor { ThemeRuntimeState.currentUIKitPalette().toolTitle }
    static var themeToolOutput: UIColor { ThemeRuntimeState.currentUIKitPalette().toolOutput }

    static var themeScrim: UIColor { ThemeRuntimeState.currentUIKitPalette().scrim }
    static var themeDimScrim: UIColor { ThemeRuntimeState.currentUIKitPalette().dimScrim }
    static var themeRecessedInset: UIColor { ThemeRuntimeState.currentUIKitPalette().recessedInset }
    static var themeOnBlue: UIColor { ThemeRuntimeState.currentUIKitPalette().onBlue }
    static var themeOnGreen: UIColor { ThemeRuntimeState.currentUIKitPalette().onGreen }

    static var themeSyntaxComment: UIColor { ThemeRuntimeState.currentUIKitPalette().syntaxComment }
    static var themeSyntaxKeyword: UIColor { ThemeRuntimeState.currentUIKitPalette().syntaxKeyword }
    static var themeSyntaxFunction: UIColor { ThemeRuntimeState.currentUIKitPalette().syntaxFunction }
    static var themeSyntaxString: UIColor { ThemeRuntimeState.currentUIKitPalette().syntaxString }
    static var themeSyntaxNumber: UIColor { ThemeRuntimeState.currentUIKitPalette().syntaxNumber }
    static var themeSyntaxType: UIColor { ThemeRuntimeState.currentUIKitPalette().syntaxType }
    static var themeSyntaxPunctuation: UIColor { ThemeRuntimeState.currentUIKitPalette().syntaxPunctuation }

    static var themeDiffAdded: UIColor { ThemeRuntimeState.currentUIKitPalette().diffAdded }
    static var themeDiffRemoved: UIColor { ThemeRuntimeState.currentUIKitPalette().diffRemoved }
    static var themeDiffContext: UIColor { ThemeRuntimeState.currentUIKitPalette().diffContext }

    /// Role fill for a themed surface. Mirrors `ThemeSurfaceStyle.resolve(_:palette:)`,
    /// which remains the only owner of surface opacity.
    static func themeSurfaceFill(_ role: ThemeSurfaceRole) -> UIColor {
        ThemeRuntimeState.currentUIKitPalette().surfaceFill(role)
    }

    /// The role's hairline stroke, when it has one.
    static func themeSurfaceStroke(_ role: ThemeSurfaceRole) -> UIColor? {
        ThemeRuntimeState.currentUIKitPalette().surfaceStroke(role)
    }
}
#endif

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
/// `View.themedSurface(_:in:)`; UIKit paths read `palette.ui.surfaceFill(_:)`.
struct ThemeSurfaceStyle {
    let fill: ThemeColor
    let stroke: ThemeColor?
    let strokeLineWidth: CGFloat
    let wantsGlassBlur: Bool

    /// The single place where per-role surface opacity is chosen.
    static func resolve(
        _ role: ThemeSurfaceRole,
        palette: ThemePalette = ThemeRuntimeState.currentPalette()
    ) -> Self {
        switch role {
        case .elevatedPanel:
            // 0.78 is the established elevated-glass translucency on dark
            // palettes; it is safe only because the role pairs with blur.
            return Self(
                fill: themedSurfaceFill(darkOpacity: 0.78, palette: palette),
                stroke: palette.fg.multiplyingAlpha(0.12),
                strokeLineWidth: 0.5,
                wantsGlassBlur: true
            )
        case .floatingControl:
            return Self(
                fill: themedSurfaceFill(darkOpacity: 0.64, palette: palette),
                stroke: palette.fg.multiplyingAlpha(0.10),
                strokeLineWidth: 1,
                wantsGlassBlur: true
            )
        case .opaqueCard:
            return Self(
                fill: themedSurfaceFill(darkOpacity: 0.92, palette: palette),
                stroke: palette.comment.multiplyingAlpha(0.22),
                strokeLineWidth: 1,
                wantsGlassBlur: false
            )
        case .popover:
            return Self(
                fill: themedSurfaceFill(darkOpacity: 0.96, palette: palette),
                stroke: nil,
                strokeLineWidth: 0,
                wantsGlassBlur: false
            )
        }
    }
}

/// Themed surface fill math: opacity keeps dark palettes glassy and raises
/// light palettes toward opaque so content behind the panel does not ghost
/// through. Private so UI code picks a `ThemeSurfaceRole` instead of ad-hoc
/// opacity values — `ThemeSurfaceStyle.resolve` is the only caller.
private func themedSurfaceFill(
    darkOpacity: Double,
    lightOpacity: Double = 0.98,
    palette: ThemePalette
) -> ThemeColor {
    palette.bgDark.multiplyingAlpha(
        ThemeColorContrast.adaptiveSurfaceOpacity(
            for: palette.bgDark,
            darkOpacity: darkOpacity,
            lightOpacity: lightOpacity
        )
    )
}

// MARK: - Theme Contrast Helpers

enum ThemeColorContrast {
    /// The runtime theme's text color for a fill: the candidate that clears the
    /// most contrast against it.
    static func foreground(for fill: ThemeColor) -> ThemeColor {
        let palette = ThemeRuntimeState.currentPalette()
        return contrastingForeground(on: fill, candidates: [palette.fg, palette.bg])
    }

    /// Pick the candidate with the stronger contrast against `fill`.
    /// Light themes can have a dark accent and a dark `fg`; using `fg`
    /// on that fill makes send arrows disappear.
    static func contrastingForeground(on fill: ThemeColor, candidates: [ThemeColor]) -> ThemeColor {
        guard let fillLuminance = relativeLuminance(of: fill) else {
            return candidates.last ?? ThemeRuntimeState.currentPalette().fg
        }
        return candidates.max { lhs, rhs in
            contrastRatio(relativeLuminance(of: lhs), fillLuminance)
                < contrastRatio(relativeLuminance(of: rhs), fillLuminance)
        } ?? candidates[0]
    }

    private static func contrastRatio(_ first: Double?, _ second: Double) -> Double {
        guard let first else { return 0 }
        let lighter = max(first, second)
        let darker = min(first, second)
        return (lighter + 0.05) / (darker + 0.05)
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
        for fill: ThemeColor,
        darkOpacity: Double,
        lightOpacity: Double = 0.98
    ) -> Double {
        guard let luminance = relativeLuminance(of: fill) else { return darkOpacity }
        let clampedLuminance = min(max(luminance, 0), 1)
        let clampedDarkOpacity = min(max(darkOpacity, 0), 1)
        let clampedLightOpacity = min(max(lightOpacity, 0), 1)
        return clampedDarkOpacity + clampedLuminance * (clampedLightOpacity - clampedDarkOpacity)
    }

    private static func relativeLuminance(of color: ThemeColor) -> Double? {
        guard let components = color.themeRGBComponents() else { return nil }
        return 0.2126 * linearize(components.red)
            + 0.7152 * linearize(components.green)
            + 0.0722 * linearize(components.blue)
    }

    private static func linearize(_ component: Double) -> Double {
        if component <= 0.03928 {
            return component / 12.92
        }
        return pow((component + 0.055) / 1.055, 2.4)
    }
}
