import UIKit

struct ToolTimelineRowStatusAppearance {
    let symbolName: String
    let statusColor: UIColor
    let borderBackgroundColor: UIColor
    let borderColor: CGColor

    static func make(isDone: Bool, isError: Bool, isInterrupted: Bool = false) -> Self {
        let palette = ThemeRuntimeState.currentPalette()
        if !isDone {
            return .init(
                symbolName: "play.circle.fill",
                statusColor: palette.ui.blue,
                borderBackgroundColor: palette.ui.toolPendingBg,
                borderColor: palette.ui.blue.withAlphaComponent(0.25).cgColor
            )
        }

        if isInterrupted {
            return .init(
                symbolName: "exclamationmark.circle.fill",
                statusColor: palette.ui.orange,
                borderBackgroundColor: palette.ui.orange.withAlphaComponent(0.08),
                borderColor: palette.ui.orange.withAlphaComponent(0.25).cgColor
            )
        }

        if isError {
            return .init(
                symbolName: "xmark.circle.fill",
                statusColor: palette.ui.red,
                borderBackgroundColor: palette.ui.toolErrorBg,
                borderColor: palette.ui.red.withAlphaComponent(0.25).cgColor
            )
        }

        return .init(
            symbolName: "checkmark.circle.fill",
            statusColor: palette.ui.green,
            borderBackgroundColor: palette.ui.toolSuccessBg,
            borderColor: palette.ui.comment.withAlphaComponent(0.2).cgColor
        )
    }
}
