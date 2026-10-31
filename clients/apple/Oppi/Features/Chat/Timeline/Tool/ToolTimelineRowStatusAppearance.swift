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
                borderColor: UIColor(palette.blue.opacity(0.25)).cgColor
            )
        }

        if isInterrupted {
            return .init(
                symbolName: "exclamationmark.circle.fill",
                statusColor: palette.ui.orange,
                borderBackgroundColor: UIColor(palette.orange.opacity(0.08)),
                borderColor: UIColor(palette.orange.opacity(0.25)).cgColor
            )
        }

        if isError {
            return .init(
                symbolName: "xmark.circle.fill",
                statusColor: palette.ui.red,
                borderBackgroundColor: palette.ui.toolErrorBg,
                borderColor: UIColor(palette.red.opacity(0.25)).cgColor
            )
        }

        return .init(
            symbolName: "checkmark.circle.fill",
            statusColor: palette.ui.green,
            borderBackgroundColor: palette.ui.toolSuccessBg,
            borderColor: UIColor(palette.comment.opacity(0.2)).cgColor
        )
    }
}
