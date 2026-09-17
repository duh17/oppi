import Foundation

/// Owns a ``ChatSessionManager`` for the lifetime of a ChatView identity.
///
/// Covered ChatView can skip `onDisappear` cleanup and then be destroyed
/// without a second disappear (iPad stack recreation, stack↔split, leave).
/// Releasing this lease still cancels the connect loop.
@MainActor
final class ChatSessionManagerLease {
    var manager: ChatSessionManager

    init(manager: ChatSessionManager) {
        self.manager = manager
    }

    deinit {
        MainActor.assumeIsolated {
            manager.cleanup()
        }
    }
}
