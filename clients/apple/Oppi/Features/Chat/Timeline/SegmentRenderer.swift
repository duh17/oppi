import UIKit

/// Converts server-rendered `[StyledSegment]` to `NSAttributedString`.
///
/// Maps segment styles to Tokyo Night theme colors.
/// Used by `ToolPresentationBuilder` and `ToolTimelineRowContentView`.
enum SegmentRenderer {

    // MARK: - Style to Color Mapping

    private static func color(for style: StyledSegment.Style?) -> UIColor {
        switch style {
        case .bold:    return UIColor.themeFg
        case .muted:   return UIColor.themeFgDim
        case .dim:     return UIColor.themeComment
        case .accent:  return UIColor.themeCyan
        case .success: return UIColor.themeGreen
        case .warning: return UIColor.themeYellow
        case .error:   return UIColor.themeRed
        case nil:      return UIColor.themeFg
        }
    }

    private static func font(for style: StyledSegment.Style?) -> UIFont {
        switch style {
        case .bold:
            return AppFont.monoMediumSemibold
        default:
            return AppFont.monoMedium
        }
    }

    // MARK: - Rendering

    /// Render segments as an attributed string for a collapsed tool row title.
    static func attributedString(from segments: [StyledSegment]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for segment in segments {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font(for: segment.style),
                .foregroundColor: color(for: segment.style),
            ]
            result.append(NSAttributedString(string: segment.text, attributes: attrs))
        }
        return result
    }

    // periphery:ignore - used by SegmentRendererTests via @testable import
    /// Extract plain text from segments (for accessibility, copy, search).
    static func plainText(from segments: [StyledSegment]) -> String {
        segments.map(\.text).joined()
    }

    /// Extract the first segment's text as a tool name prefix (for the icon).
    /// Returns the text up to the first space if the first segment is bold.
    static func toolNamePrefix(from segments: [StyledSegment]) -> String? {
        guard let first = segments.first, first.style == .bold else { return nil }
        return first.text.trimmingCharacters(in: .whitespaces)
    }

    /// Map a segment style to a UIColor (for icon tinting etc).
    static func toolNameColor(from segments: [StyledSegment]) -> UIColor? {
        guard let first = segments.first else { return nil }
        return color(for: first.style)
    }

    // periphery:ignore - used by SegmentRendererTests via @testable import
    /// Render result segments as a trailing badge string.
    /// Returns nil if segments are empty or all whitespace.
    static func trailingText(from segments: [StyledSegment]) -> String? {
        let text = plainText(from: segments).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Render segments, stripping the first bold segment (tool name prefix).
    /// Used when the tool has an SF Symbol icon that already represents the tool name,
    /// so showing the name as text would be redundant.
    static func attributedStringStrippingPrefix(from segments: [StyledSegment]) -> NSAttributedString {
        guard let first = segments.first, first.style == .bold else {
            return attributedString(from: segments)
        }

        let remaining = Array(segments.dropFirst())
        let result = NSMutableAttributedString()
        for (index, segment) in remaining.enumerated() {
            var text = segment.text
            // Trim leading whitespace from the segment immediately after the stripped prefix
            if index == 0 {
                text = String(text.drop(while: { $0 == " " }))
            }
            guard !text.isEmpty else { continue }
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font(for: segment.style),
                .foregroundColor: color(for: segment.style),
            ]
            result.append(NSAttributedString(string: text, attributes: attrs))
        }
        return result
    }

    /// Render result segments as an attributed trailing badge.
    static func trailingAttributedString(from segments: [StyledSegment]) -> NSAttributedString? {
        guard !segments.isEmpty else { return nil }
        let result = NSMutableAttributedString()
        for segment in segments {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: segment.style == .bold ? AppFont.monoSmallSemibold : AppFont.monoSmall,
                .foregroundColor: color(for: segment.style),
            ]
            result.append(NSAttributedString(string: segment.text, attributes: attrs))
        }
        return result.length > 0 ? result : nil
    }
}
