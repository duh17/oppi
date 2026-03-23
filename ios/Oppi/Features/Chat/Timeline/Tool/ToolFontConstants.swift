import UIKit

/// Shared monospaced font constants for tool timeline rows.
///
/// Delegates to `AppFont` — these are convenience aliases that preserve
/// the existing `ToolFont.*` API used throughout tool row code.
/// Uses computed properties so values update when font preferences change.
enum ToolFont {
    /// Small: line numbers, counters, secondary labels (10pt)
    static var small: UIFont { AppFont.monoSmall }
    static var smallBold: UIFont { AppFont.monoSmallSemibold }
    /// Regular: code content, output text, expanded labels (11pt)
    static var regular: UIFont { AppFont.mono }
    static var regularBold: UIFont { AppFont.monoBold }
    /// Title: section headers, tool names (12pt)
    static var title: UIFont { AppFont.monoMediumSemibold }
    static var titleRegular: UIFont { AppFont.monoMedium }
}
