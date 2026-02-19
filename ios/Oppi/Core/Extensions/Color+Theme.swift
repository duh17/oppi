import SwiftUI

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
