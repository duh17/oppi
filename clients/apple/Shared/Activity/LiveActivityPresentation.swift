import SwiftUI

/// What the counts-only card says and how it looks. Shared by the widget extension and the
/// app's screenshot previews.
enum LiveActivityPresentation {
    /// "3 running · 1 needs you", "2 running", "1 needs you", or "All done".
    static func summary(_ state: OppiActivityAttributes.ContentState) -> String {
        var parts: [String] = []
        if state.running > 0 {
            parts.append(String(localized: "\(state.running) running"))
        }
        if state.needsYou > 0 {
            parts.append(
                state.needsYou == 1
                    ? String(localized: "1 needs you")
                    : String(localized: "\(state.needsYou) need you")
            )
        }
        return parts.isEmpty ? String(localized: "All done") : parts.joined(separator: " · ")
    }

    /// Waiting on the person leads: a hand while anything needs you.
    static func symbol(_ state: OppiActivityAttributes.ContentState) -> String {
        if state.needsYou > 0 { return "hand.raised.fill" }
        if state.running > 0 { return "waveform.path.ecg" }
        return "checkmark.circle.fill"
    }

    static func color(_ state: OppiActivityAttributes.ContentState) -> Color {
        if state.needsYou > 0 { return needsYouColor }
        if state.running > 0 { return runningColor }
        return doneColor
    }

    static let runningColor = Color(red: 0.48, green: 0.64, blue: 0.97)
    static let needsYouColor = Color(red: 0.98, green: 0.52, blue: 0.18)
    static let doneColor = Color(red: 0.35, green: 0.86, blue: 0.62)
}
