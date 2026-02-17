import Foundation

extension Duration {
    /// Milliseconds as a simple integer for logging.
    var ms: Int {
        let (seconds, attoseconds) = components
        return Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000)
    }
}
