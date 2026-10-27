import UIKit

/// Row content the MCP screens share.
enum McpRowContent {
    /// A title and its value as the Storage page draws them: the system value
    /// cell breaks between words, and stacks title over value at accessibility
    /// text sizes.
    @MainActor
    static func value(_ title: String, _ value: String) -> UIListContentConfiguration {
        var content = UIListContentConfiguration.valueCell()
        content.text = title
        content.secondaryText = value
        return content
    }
}
