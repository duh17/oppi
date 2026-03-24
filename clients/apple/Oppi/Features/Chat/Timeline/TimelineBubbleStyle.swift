import UIKit

/// Named visual constants for timeline row bubble/chip styling.
///
/// Centralises magic numbers scattered across row content views so
/// visual tweaks propagate everywhere in one change.
enum TimelineBubbleStyle {
    // MARK: - Corner Radii

    /// Standard message bubble (assistant, user, thinking, compaction).
    static let bubbleCornerRadius: CGFloat = 10

    /// Compact chip rows (permission, audio clip).
    static let chipCornerRadius: CGFloat = 8

    /// Inset elements inside a bubble (user image thumbnails).
    static let thumbnailCornerRadius: CGFloat = 8

    // MARK: - Background Alpha

    /// Subtle bubble tint shared across assistant (purple), thinking-done
    /// (comment), and permission-outcome rows.
    static let subtleBgAlpha: CGFloat = 0.08

    /// Lighter variant used for thinking-streaming bubbles.
    static let streamingBgAlpha: CGFloat = 0.06

    /// Strong tint for error rows.
    static let errorBgAlpha: CGFloat = 0.18

    /// User thumbnail border alpha (over comment color).
    static let thumbnailBorderAlpha: CGFloat = 0.3
}
