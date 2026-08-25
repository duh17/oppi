import Foundation

/// One live-streaming owner for apply cadence and inner viewport follow.
///
/// Apply stays on `AssistantMarkdownContentView`. Thinking stays plain text
/// while it streams. This type is the only flush clock and the only
/// attached / detached / settle policy for inner streaming viewports.
enum LiveStreamingPresentation {
    /// Matches `DeltaCoalescer`. Extra presentation timers must not invent
    /// a second clock.
    static let flushInterval: Duration = .milliseconds(50)

    /// Pure attached / detached / settle policy used by thinking bubbles,
    /// write-tool markdown viewports, and mutable fullscreen.
    struct ViewportPolicy: Equatable, Sendable {
        enum Intent: Equatable, Sendable {
            case none
            case preserveAnchor
            case followTail
            case explicitFocus
        }

        enum Event: Equatable, Sendable {
            case streamStarted
            case streamCompleted
            case interactionBegan
            case interactionEnded(isNearBottom: Bool, isStreaming: Bool)
            case requestPreserveAnchor
            case requestFollowTail
            case requestExplicitFocus
        }

        private(set) var isInteracting = false
        private(set) var followsTail: Bool

        init(followsTail: Bool) {
            self.followsTail = followsTail
        }

        mutating func handle(_ event: Event) -> Intent {
            switch event {
            case .streamStarted:
                if !isInteracting { followsTail = true }
                return .none
            case .streamCompleted:
                followsTail = false
                return .none
            case .interactionBegan:
                isInteracting = true
                followsTail = false
                return .none
            case .interactionEnded(let isNearBottom, let isStreaming):
                isInteracting = false
                followsTail = isNearBottom && isStreaming
                return followsTail ? .followTail : .none
            case .requestPreserveAnchor:
                return isInteracting ? .none : .preserveAnchor
            case .requestFollowTail:
                return !isInteracting && followsTail ? .followTail : .none
            case .requestExplicitFocus:
                return isInteracting ? .none : .explicitFocus
            }
        }

        /// Shared attach / complete rules for inner streaming viewports.
        ///
        /// First live tick and non-continuation reuse attach. Ordinary
        /// appends keep the current attached / detached state. Completion
        /// always detaches so the reader can settle.
        mutating func applyStreamTick(
            isStreaming: Bool,
            shouldRerender: Bool,
            wasVisible: Bool,
            previousText: String?,
            currentText: String
        ) -> Intent {
            if isStreaming {
                let isContinuation = previousText.map {
                    !$0.isEmpty && currentText.hasPrefix($0)
                } ?? false
                if !wasVisible || previousText == nil || (!isContinuation && shouldRerender) {
                    return handle(.streamStarted)
                }
                return .none
            }
            return handle(.streamCompleted)
        }
    }
}
