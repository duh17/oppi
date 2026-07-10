import Foundation
import OSLog

struct QuickSessionInitialPayload: Equatable, Sendable {
    struct Attachment: Equatable, Sendable {
        let name: String
        let data: Data
        let mimeType: String
    }

    let text: String?
    let attachments: [Attachment]
}

enum QuickSessionPendingPayload: Equatable, Sendable {
    case share(ShareQuickSessionPayload)
    case initial(QuickSessionInitialPayload)
}

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

    /// Input owned by the latest accepted presentation request. Keeping the
    /// payload and request in one slot prevents separate intake paths from
    /// merging unrelated content into the same draft.
    private var pendingPayload: QuickSessionPendingPayload?

    private init() {}

    /// Called by presentation sources that do not carry initial content.
    func requestPresentation() {
        requestPresentation(pendingPayload: nil)
    }

    /// Check shared UserDefaults for a pending request from an extension.
    /// Called on app foreground.
    func checkForPendingRequest() {
        let defaults = SharedConstants.sharedDefaults
        let pending = defaults.bool(forKey: SharedConstants.quickSessionPendingKey)
        guard pending else { return }

        let payload: ShareQuickSessionPayload?
        if let payloadId = defaults.string(forKey: ShareQuickSessionPayload.pendingPayloadIdKey) {
            payload = ShareQuickSessionPayload.consume(id: payloadId)
        } else {
            defaults.removeObject(forKey: SharedConstants.quickSessionPendingKey)
            payload = nil
        }

        logger.notice("Found pending quick session request from extension")
        let pendingPayload = payload.map(QuickSessionPendingPayload.share)
        if !requestPresentation(pendingPayload: pendingPayload), let payload {
            ShareQuickSessionPayload.removePayloadFiles(id: payload.id)
        }
    }

    func requestPresentation(sharePayloadId: String) {
        let payload = ShareQuickSessionPayload.consume(id: sharePayloadId)
        let pendingPayload = payload.map(QuickSessionPendingPayload.share)
        if !requestPresentation(pendingPayload: pendingPayload), let payload {
            ShareQuickSessionPayload.removePayloadFiles(id: payload.id)
        }
    }

    func requestPresentation(initialPayload: QuickSessionInitialPayload?) {
        requestPresentation(pendingPayload: initialPayload.map(QuickSessionPendingPayload.initial))
    }

    func consumePendingPayload() -> QuickSessionPendingPayload? {
        defer { pendingPayload = nil }
        return pendingPayload
    }

    @discardableResult
    private func requestPresentation(pendingPayload newPayload: QuickSessionPendingPayload?) -> Bool {
        guard !isPresented else {
            logger.debug("Quick session sheet already presented, ignoring duplicate request")
            return false
        }

        if case .share(let previousPayload) = pendingPayload {
            ShareQuickSessionPayload.removePayloadFiles(id: previousPayload.id)
        }
        pendingPayload = newPayload
        presentationRequestID += 1
        logger.notice("Quick session presentation requested (id=\(self.presentationRequestID, privacy: .public))")
        return true
    }
}
