import Foundation

extension Date {
    /// Current time as milliseconds since Unix epoch.
    static func nowMs() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1_000).rounded())
    }
}
