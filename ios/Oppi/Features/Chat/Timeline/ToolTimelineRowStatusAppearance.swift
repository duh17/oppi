import SwiftUI
import UIKit

struct ToolTimelineRowStatusAppearance {
    let symbolName: String
    let statusColor: UIColor
    let borderBackgroundColor: UIColor
    let borderColor: CGColor

    static func make(isDone: Bool, isError: Bool) -> Self {
        if !isDone {
            return .init(
                symbolName: "play.circle.fill",
                statusColor: UIColor(Color.themeBlue),
                borderBackgroundColor: UIColor(Color.themeBgHighlight.opacity(0.75)),
                borderColor: UIColor(Color.themeBlue.opacity(0.25)).cgColor
            )
        }

        if isError {
            return .init(
                symbolName: "xmark.circle.fill",
                statusColor: UIColor(Color.themeRed),
                borderBackgroundColor: UIColor(Color.themeRed.opacity(0.08)),
                borderColor: UIColor(Color.themeRed.opacity(0.25)).cgColor
            )
        }

        return .init(
            symbolName: "checkmark.circle.fill",
            statusColor: UIColor(Color.themeGreen),
            borderBackgroundColor: UIColor(Color.themeGreen.opacity(0.06)),
            borderColor: UIColor(Color.themeComment.opacity(0.2)).cgColor
        )
    }
}
