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

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "QuickSessionTrigger")

/// Lightweight trigger that bridges external intake with SwiftUI presentation.
///
/// Control and main-app App Intents request presentation directly and may
/// include an initial composer payload. The share extension sends directly and
/// never hands a draft to the main app.
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
    private var pendingPayload: QuickSessionInitialPayload?

    private init() {}

    /// Called by presentation sources that do not carry initial content.
    func requestPresentation() {
        requestPresentation(initialPayload: nil)
    }

    /// Routes a system control's resolved destination into SwiftUI presentation.
    func requestPresentation(for intent: QuickSessionOpenIntent) {
        switch intent.target {
        case .quickSession:
            requestPresentation()
        }
    }

    func requestPresentation(initialPayload: QuickSessionInitialPayload?) {
        guard !isPresented else {
            logger.debug("Quick session sheet already presented, ignoring duplicate request")
            return
        }
        pendingPayload = initialPayload
        presentationRequestID += 1
        logger.notice("Quick session presentation requested (id=\(self.presentationRequestID, privacy: .public))")
    }

    func consumePendingPayload() -> QuickSessionInitialPayload? {
        defer { pendingPayload = nil }
        return pendingPayload
    }

}
