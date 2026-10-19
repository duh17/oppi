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

/// Everything one Quick Session presentation starts with: where (server, workspace, Agent,
/// thread), how (composer, dictation, or a Live Voice call), and any text or image to put
/// in it. In-app buttons, system controls, and Shortcuts all describe a start this way.
struct QuickSessionStart: Equatable, Sendable {
    var context: QuickSessionLaunchContext?
    var mode: QuickSessionMode = .message
    var payload: QuickSessionInitialPayload?
}

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "QuickSessionTrigger")

/// Lightweight trigger that bridges external intake with SwiftUI presentation.
///
/// Control and main-app App Intents request presentation directly with a
/// `QuickSessionStart`. The share extension sends directly and never hands a
/// draft to the main app.
@MainActor @Observable
final class QuickSessionTrigger {
    static let shared = QuickSessionTrigger()

    /// Bumped each time a presentation is requested. SwiftUI observes this
    /// and presents the sheet when it changes from 0 to non-zero.
    private(set) var presentationRequestID: Int = 0

    /// Set to true by the sheet when presented, cleared on dismiss.
    /// Prevents duplicate presentations from rapid intent firings.
    var isPresented: Bool = false

    /// Start owned by the latest accepted presentation request. Keeping the
    /// start and request in one slot prevents separate intake paths from
    /// merging unrelated content into the same draft.
    private var pendingStart: QuickSessionStart?

    private init() {}

    /// Routes a system control's mode into presentation.
    func requestPresentation(for intent: QuickSessionOpenIntent) {
        requestPresentation(QuickSessionStart(mode: intent.target))
    }

    /// While Oppi is locked the sheet waits for unlock, so it never opens
    /// behind the lock cover.
    func requestPresentation(_ start: QuickSessionStart = QuickSessionStart()) {
        AppLockService.shared.performWhenUnlocked { [self] in
            present(start)
        }
    }

    private func present(_ start: QuickSessionStart) {
        guard !isPresented else {
            logger.debug("Quick session sheet already presented, ignoring duplicate request")
            return
        }
        pendingStart = start
        presentationRequestID += 1
        logger.notice(
            "Quick session presentation requested (id=\(self.presentationRequestID, privacy: .public) mode=\(start.mode.rawValue, privacy: .public))"
        )
    }

    func consumePendingStart() -> QuickSessionStart? {
        defer { pendingStart = nil }
        return pendingStart
    }

}
