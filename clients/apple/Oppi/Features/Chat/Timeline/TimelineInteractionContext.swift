import Foundation

/// Lightweight holder for selected-text π interaction state.
///
/// Lives on `ChatTimelineControllerContext` and is queried at apply-time
/// by row content views that support inline text selection and π actions.
/// Eliminates per-row threading of `selectedTextPiRouter` /
/// `selectedTextSourceContext` through every UIContentConfiguration struct.
@MainActor
final class TimelineInteractionContext {
    var selectedTextPiRouter: SelectedTextPiActionRouter?
    var sessionId: String = ""

    /// Build a `SelectedTextSourceContext` for the given surface.
    func sourceContext(
        surface: SelectedTextSurfaceKind,
        sourceLabel: String? = nil,
        filePath: String? = nil,
        lineRange: ClosedRange<Int>? = nil,
        languageHint: String? = nil
    ) -> SelectedTextSourceContext? {
        guard selectedTextPiRouter != nil else { return nil }
        return SelectedTextSourceContext(
            sessionId: sessionId,
            surface: surface,
            sourceLabel: sourceLabel,
            filePath: filePath,
            lineRange: lineRange,
            languageHint: languageHint
        )
    }
}
