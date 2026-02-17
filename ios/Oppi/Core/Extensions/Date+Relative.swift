import Foundation

extension Date {
    /// Relative time string: "just now", "2m ago", "1h ago", "3d ago".
    func relativeString(relativeTo now: Date = Date()) -> String {
        let interval = max(0, now.timeIntervalSince(self))

        if interval < 60 {
            return "just now"
        } else if interval < 3600 {
            let minutes = Int(interval / 60)
            return "\(minutes)m ago"
        } else if interval < 86400 {
            let hours = Int(interval / 3600)
            return "\(hours)h ago"
        } else {
            let days = Int(interval / 86400)
            return "\(days)d ago"
        }
    }
}
