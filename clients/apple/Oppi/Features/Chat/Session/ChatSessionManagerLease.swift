import Foundation

/// Owns a ``ChatSessionManager`` for the lifetime of a ChatViewController identity.
///
/// A covered chat can skip its disappearance cleanup and then be destroyed
/// without a second disappear (iPad stack recreation, stack↔split, leave).
/// Releasing this lease still cancels the connect loop and releases still-owned focus.
@MainActor
final class ChatSessionManagerLease {
    let manager: ChatSessionManager

    init(manager: ChatSessionManager) {
        self.manager = manager
    }

    deinit {
        MainActor.assumeIsolated {
            manager.cleanup()
        }
    }
}
