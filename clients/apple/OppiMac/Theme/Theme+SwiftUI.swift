import SwiftUI

// The Mac's SwiftUI face of the theme: `Color.theme*` snapshot accessors, the
// environment-resolved `ThemeShapeStyle`, the themed-surface modifiers, and the
// `\.theme`/`\.themeID` environment values. It ships in `OppiMac` only, so the
// theme model (`AppTheme`, `ThemeStore`, `ThemeCatalog`, `ThemeContrast`,
// `RemoteTheme`, `Color+Theme.swift`) imports no SwiftUI. There `ThemeColor` is
// this platform's `Color`, so a palette token and an `AppTheme` token are the
// colors these helpers hand SwiftUI, unchanged.
//
// The UIKit side lives in `Oppi/Core/Extensions/Color+Theme.swift` (the
// `UIColor.theme*` accessors, `ThemeSurfaceRole`/`ThemeSurfaceStyle`, and
// `ThemeColorContrast`), which both targets compile.

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

    static var themeToolSuccessBg: Color { palette.toolSuccessBg }
    static var themeToolTitle: Color { palette.toolTitle }
    static var themeToolOutput: Color { palette.toolOutput }

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

    static var themeOnBlue: Color { ThemeColorContrast.foreground(for: palette.blue) }
    static var themeOnGreen: Color { ThemeColorContrast.foreground(for: palette.green) }

    // MARK: - Semantic Syntax

    static var themeSyntaxComment: Color { palette.syntaxComment }
    static var themeSyntaxKeyword: Color { palette.syntaxKeyword }
    static var themeSyntaxFunction: Color { palette.syntaxFunction }
    static var themeSyntaxString: Color { palette.syntaxString }
    static var themeSyntaxNumber: Color { palette.syntaxNumber }
    static var themeSyntaxType: Color { palette.syntaxType }
    static var themeSyntaxPunctuation: Color { palette.syntaxPunctuation }

    // MARK: - Semantic Diff

    static var themeDiffAdded: Color { palette.toolDiffAdded }
    static var themeDiffRemoved: Color { palette.toolDiffRemoved }
    static var themeDiffContext: Color { palette.toolDiffContext }
}

/// Environment-resolved theme style for SwiftUI foregrounds, fills, strokes,
/// and style-based backgrounds. Unlike `Color.theme*`, this registers a real
/// `EnvironmentValues.theme` dependency, so persistent List/LazyVStack cells
/// repaint when the active theme changes instead of retaining captured colors.
struct ThemeShapeStyle: ShapeStyle {
    enum Role: Equatable, Sendable {
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
        case dimScrim
        case recessedInset
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
        case toolPendingBackground
        case toolSuccessBackground
        case toolErrorBackground
        case toolTitle
        case toolOutput
    }

    let role: Role

    func resolve(in environment: EnvironmentValues) -> some ShapeStyle {
        color(in: environment)
    }

    func color(in environment: EnvironmentValues) -> Color {
        let theme = environment.theme
        let palette = environment.themeID.palette
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
        case .dimScrim: theme.bg.primary.opacity(0.5)
        case .recessedInset: theme.bg.primary.opacity(0.30)
        case .onBlue:
            ThemeColorContrast.contrastingForeground(
                on: theme.accent.blue,
                candidates: [theme.text.primary, theme.bg.primary]
            )
        case .onGreen:
            ThemeColorContrast.contrastingForeground(
                on: theme.accent.green,
                candidates: [theme.text.primary, theme.bg.primary]
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
        // Tool surfaces are authored semantic palette tokens rather than
        // reconstructed accent washes. This preserves imported themes and
        // repaints mounted Mac rows when the live theme changes.
        case .toolPendingBackground: palette.toolPendingBg
        case .toolSuccessBackground: palette.toolSuccessBg
        case .toolErrorBackground: palette.toolErrorBg
        case .toolTitle: palette.toolTitle
        case .toolOutput: palette.toolOutput
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
    static var themeDimScrim: ThemeShapeStyle { ThemeShapeStyle(role: .dimScrim) }
    static var themeRecessedInset: ThemeShapeStyle { ThemeShapeStyle(role: .recessedInset) }
    static var themeOnBlue: ThemeShapeStyle { ThemeShapeStyle(role: .onBlue) }
    static var themeOnGreen: ThemeShapeStyle { ThemeShapeStyle(role: .onGreen) }

    static var themeSyntaxComment: ThemeShapeStyle { ThemeShapeStyle(role: .syntaxComment) }
    static var themeSyntaxKeyword: ThemeShapeStyle { ThemeShapeStyle(role: .syntaxKeyword) }
    static var themeSyntaxFunction: ThemeShapeStyle { ThemeShapeStyle(role: .syntaxFunction) }
    static var themeSyntaxString: ThemeShapeStyle { ThemeShapeStyle(role: .syntaxString) }
    static var themeSyntaxNumber: ThemeShapeStyle { ThemeShapeStyle(role: .syntaxNumber) }
    static var themeSyntaxType: ThemeShapeStyle { ThemeShapeStyle(role: .syntaxType) }
    static var themeSyntaxPunctuation: ThemeShapeStyle { ThemeShapeStyle(role: .syntaxPunctuation) }
    static var themeDiffAdded: ThemeShapeStyle { ThemeShapeStyle(role: .diffAdded) }
    static var themeDiffRemoved: ThemeShapeStyle { ThemeShapeStyle(role: .diffRemoved) }
    static var themeToolSuccessBg: ThemeShapeStyle { ThemeShapeStyle(role: .toolSuccessBackground) }
    static var themeToolTitle: ThemeShapeStyle { ThemeShapeStyle(role: .toolTitle) }
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
        // swiftlint:disable:next redundant_discardable_let - ViewBuilder needs let _ to read themeID
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
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content.background(theme.bg.primary.ignoresSafeArea())
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

// MARK: - Environment

private struct ThemeKey: EnvironmentKey {
    static var defaultValue: AppTheme {
        ThemeRuntimeState.currentThemeID().appTheme
    }
}

private struct ThemeIDKey: EnvironmentKey {
    static var defaultValue: ThemeID {
        ThemeRuntimeState.currentThemeID()
    }
}

extension EnvironmentValues {
    var theme: AppTheme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }

    var themeID: ThemeID {
        get { self[ThemeIDKey.self] }
        set { self[ThemeIDKey.self] = newValue }
    }
}

/// The SwiftUI side of a theme, for `.preferredColorScheme` and for the window
/// appearance the Mac's sync view reports back.
extension ThemeColorScheme {
    var colorScheme: ColorScheme {
        self == .light ? .light : .dark
    }

    init(_ colorScheme: ColorScheme) {
        self = colorScheme == .light ? .light : .dark
    }
}
