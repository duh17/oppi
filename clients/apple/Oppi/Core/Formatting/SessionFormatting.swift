import Foundation

/// Shared formatting helpers for session display (model names, costs, durations).
/// Used by SessionRow, WorkspaceContextBar, and other session views.
enum SessionFormatting {

    /// Extract the short model name from a "provider/model-id" string.
    static func shortModelName(_ model: String?) -> String? {
        guard let model, !model.isEmpty else { return nil }
        return model.split(separator: "/").last.map(String.init) ?? model
    }

    /// Format a cost value as a dollar string (e.g. "$1.23", "$0.004").
    static func costString(_ cost: Double) -> String {
        if cost >= 0.01 {
            let cents = Int((cost * 100).rounded())
            let d = cents / 100
            let r = cents % 100
            return "$\(d).\(r < 10 ? "0" : "")\(r)"
        } else {
            let mils = Int((cost * 1000).rounded())
            if mils < 10 { return "$0.00\(mils)" }
            if mils < 100 { return "$0.0\(mils)" }
            return "$0.\(mils)"
        }
    }

    /// Format elapsed time since a date as a compact string (e.g. "3s", "5m", "2h14m").
    static func durationString(since date: Date) -> String {
        let elapsed = Int(Date().timeIntervalSince(date))
        if elapsed < 60 { return "\(elapsed)s" }
        let minutes = elapsed / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        return "\(hours)h\(remainingMinutes)m"
    }
}
