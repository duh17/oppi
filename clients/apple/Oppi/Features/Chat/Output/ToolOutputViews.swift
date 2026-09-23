import Foundation

// MARK: - ToolPresentationBuilder helpers that remain iOS-specific

extension ToolPresentationBuilder {
    static func formatDuration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "" }
        let total = Int(seconds.rounded())
        let minutes = total / 60
        let remaining = total % 60
        if minutes > 0 {
            return String(format: "%d:%02d", minutes, remaining)
        }
        return String(format: "0:%02d", remaining)
    }
}
