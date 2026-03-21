import UIKit

/// Shared monospaced font constants for tool timeline rows.
enum ToolFont {
    /// Small: line numbers, counters, secondary labels (10pt)
    static let small = UIFont.monospacedSystemFont(ofSize: 10, weight: .regular)
    static let smallBold = UIFont.monospacedSystemFont(ofSize: 10, weight: .semibold)
    /// Regular: code content, output text, expanded labels (11pt)
    static let regular = UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    static let regularBold = UIFont.monospacedSystemFont(ofSize: 11, weight: .bold)
    /// Title: section headers, tool names (12pt)
    static let title = UIFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
    static let titleRegular = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
}
