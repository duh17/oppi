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

    /// Format token count as compact string: 200000 → "200k", 1500000 → "1.5M".
    static func tokenCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            let m = Double(count) / 1_000_000
            return m == m.rounded() ? String(format: "%.0fM", m) : String(format: "%.1fM", m)
        }
        if count >= 1_000 {
            let k = Double(count) / 1_000
            return k == k.rounded() ? String(format: "%.0fk", k) : String(format: "%.1fk", k)
        }
        return "\(count)"
    }

    /// Format token count with locale-aware decimal separators: 200000 → "200,000".
    static func tokenCountDecimal(_ count: Int) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: count), number: .decimal)
    }

    /// Format byte count for display: 1234 → "1.2 KB", 5242880 → "5.0 MB".
    static func byteCount(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        let kb = Double(bytes) / 1024
        if kb < 1024 { return String(format: "%.1f KB", kb) }
        let mb = kb / 1024
        return String(format: "%.1f MB", mb)
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
