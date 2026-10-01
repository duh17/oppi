import Foundation

/// Framework-free display facts for extension native blocks and widget lines.
///
/// Platform painters read these instead of re-deriving state wording, progress
/// clamping, link validity, or widget-line conventions, so the iOS UIKit
/// renderer and any later painter agree on behavior.
enum ExtensionNativeBlockPresentation {
    /// Activity row state tone, independent of any color system.
    enum ActivityTone: Equatable, Sendable {
        case running, success, warning, error, queued, inactive, neutral
    }

    static func activityTone(_ state: String?) -> ActivityTone {
        switch state {
        case "running": .running
        case "success": .success
        case "warning": .warning
        case "error": .error
        case "queued": .queued
        case "inactive": .inactive
        default: .neutral
        }
    }

    static func activityStateAccessibilityText(_ state: String?) -> String? {
        switch activityTone(state) {
        case .running: "Working"
        case .success: "Done"
        case .warning: "Warning"
        case .error: "Error"
        case .queued: "Queued"
        case .inactive: "Not started"
        case .neutral: nil
        }
    }

    /// Clamps a progress fraction to 0...1; non-finite or missing values are nil.
    static func normalizedProgress(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return min(max(value, 0), 1)
    }

    static func percentText(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded())) percent"
    }

    static func activityRowURL(_ row: ExtensionUIActivityRow) -> URL? {
        linkURL(row.link)
    }

    /// Structured links stay real URLs with a scheme; anything else is not a link.
    static func linkURL(_ link: String?) -> URL? {
        guard let link, let url = URL(string: link), url.scheme?.isEmpty == false else { return nil }
        return url
    }

    static func activityRowAccessibilityLabel(_ row: ExtensionUIActivityRow) -> String {
        joinedNonEmpty([row.title, row.subtitle, row.detail], separator: ", ")
    }

    static func activityRowAccessibilityValue(_ row: ExtensionUIActivityRow) -> String {
        joinedNonEmpty(
            [
                activityStateAccessibilityText(row.state),
                normalizedProgress(row.progress).map(percentText),
            ],
            separator: ", "
        )
    }

    // MARK: - Terminal widget lines

    /// How a plain `setWidget(string[])` line paints. Pi widgets draw status
    /// headers as `● title` (active) / `○ title` (idle) and nested activity under
    /// `⎿`; this keeps those terminal conventions readable without parsing
    /// arbitrary art.
    enum WidgetLineStyle: Equatable, Sendable {
        case header(title: String, isActive: Bool)
        case text(isActivity: Bool)
    }

    static func widgetLineStyle(_ line: String) -> WidgetLineStyle {
        let trimmed = ANSIParser.strip(line).trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("● ") || trimmed.hasPrefix("○ ") {
            return .header(title: String(trimmed.dropFirst(2)), isActive: trimmed.hasPrefix("●"))
        }
        return .text(isActivity: trimmed.contains("⎿"))
    }

    private static func joinedNonEmpty(_ values: [String?], separator: String) -> String {
        values
            .compactMap { value in
                let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return trimmed.isEmpty ? nil : trimmed
            }
            .joined(separator: separator)
    }
}
