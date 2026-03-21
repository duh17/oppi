import UIKit

/// Shared monospaced font constants for tool timeline rows.
///
/// Delegates to `AppFont` — these are convenience aliases that preserve
/// the existing `ToolFont.*` API used throughout tool row code.
enum ToolFont {
    /// Small: line numbers, counters, secondary labels (10pt)
    static let small = AppFont.monoSmall
    static let smallBold = AppFont.monoSmallSemibold
    /// Regular: code content, output text, expanded labels (11pt)
    static let regular = AppFont.mono
    static let regularBold = AppFont.monoBold
    /// Title: section headers, tool names (12pt)
    static let title = AppFont.monoMediumSemibold
    static let titleRegular = AppFont.monoMedium
}
