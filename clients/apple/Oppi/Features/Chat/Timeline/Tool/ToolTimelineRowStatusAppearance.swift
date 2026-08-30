import SwiftUI
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
                statusColor: UIColor(palette.blue),
                borderBackgroundColor: UIColor(palette.toolPendingBg),
                borderColor: UIColor(palette.blue.opacity(0.25)).cgColor
            )
        }

        if isInterrupted {
            return .init(
                symbolName: "exclamationmark.circle.fill",
                statusColor: UIColor(palette.orange),
                borderBackgroundColor: UIColor(palette.orange.opacity(0.08)),
                borderColor: UIColor(palette.orange.opacity(0.25)).cgColor
            )
        }

        if isError {
            return .init(
                symbolName: "xmark.circle.fill",
                statusColor: UIColor(palette.red),
                borderBackgroundColor: UIColor(palette.toolErrorBg),
                borderColor: UIColor(palette.red.opacity(0.25)).cgColor
            )
        }

        return .init(
            symbolName: "checkmark.circle.fill",
            statusColor: UIColor(palette.green),
            borderBackgroundColor: UIColor(palette.toolSuccessBg),
            borderColor: UIColor(palette.comment.opacity(0.2)).cgColor
        )
    }
}
