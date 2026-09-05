import UIKit

/// Thread-safe wrapper for sending immutable `NSAttributedString` across
/// isolation boundaries without the lossy `AttributedString` round-trip.
///
/// `NSAttributedString` is immutable and thread-safe in practice, but the
/// compiler doesn't know that. This wrapper marks it `@unchecked Sendable`
/// so we can return it from `Task.detached` without converting through
/// Swift's `AttributedString` (which drops custom attributes and can
/// produce attribute runs that crash UIKit's internal `NSMutableRLEArray`).
struct SendableNSAttributedString: @unchecked Sendable {
    let value: NSAttributedString

    init(_ value: NSAttributedString) {
        self.value = value
    }
}
