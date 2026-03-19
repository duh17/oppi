import Foundation
import OSLog

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "QuickSessionTrigger")

/// Lightweight trigger that bridges App Intents with the SwiftUI presentation layer.
///
/// The intent (running possibly out-of-process via widget extension) writes
/// a flag to shared UserDefaults. The main app observes `presentationRequestID`
/// and presents the Quick Session sheet when it changes.
///
/// For in-process intents (Action Button / Spotlight), the intent calls
/// `requestPresentation()` directly.
@MainActor @Observable
final class QuickSessionTrigger {
    static let shared = QuickSessionTrigger()

    /// Bumped each time a presentation is requested. SwiftUI observes this
    /// and presents the sheet when it changes from 0 to non-zero.
    private(set) var presentationRequestID: Int = 0

    /// Set to true by the sheet when presented, cleared on dismiss.
    /// Prevents duplicate presentations from rapid intent firings.
    var isPresented: Bool = false

    private init() {}

    /// Called by `StartQuickSessionIntent.perform()` to request sheet presentation.
    func requestPresentation() {
        guard !isPresented else {
            logger.debug("Quick session sheet already presented, ignoring duplicate request")
            return
        }
        presentationRequestID += 1
        logger.notice("Quick session presentation requested (id=\(self.presentationRequestID, privacy: .public))")
    }

    /// Check shared UserDefaults for a pending request from the widget extension.
    /// Called on app foreground.
    func checkForPendingRequest() {
        let defaults = SharedConstants.sharedDefaults
        let pending = defaults.bool(forKey: SharedConstants.quickSessionPendingKey)
        guard pending else { return }

        // Clear the flag immediately
        defaults.removeObject(forKey: SharedConstants.quickSessionPendingKey)

        logger.notice("Found pending quick session request from extension")
        requestPresentation()
    }
}
