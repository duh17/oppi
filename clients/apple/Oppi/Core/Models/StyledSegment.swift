import Foundation

/// A styled text segment for tool call/result display.
///
/// Pre-rendered by the server to produce collapsed summary lines.
/// iOS maps styles to theme colors via ``SegmentRenderer``.
struct StyledSegment: Codable, Sendable, Equatable {
    let text: String
    let style: Style?

    enum Style: String, Codable, Sendable {
        case bold
        case muted
        case dim
        case accent
        case success
        case warning
        case error
    }
}
