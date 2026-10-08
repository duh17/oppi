import Foundation

/// Focused-session routing target. `generation` doubles as the ownership claim
/// a chat runtime holds: only the holder of the current context may release it.
struct FocusedSessionContext: Equatable, Sendable {
    let sessionId: String
    let generation: Int
}

/// The chat runtime behind a claim. When a newer claim on the same session is
/// released, focus returns to the newest older claim whose runtime is still
/// mounted, and `regain` tells that runtime to keep or rebind its stream.
struct FocusClaimHolder {
    /// One per runtime: its new claim replaces any older claim it still holds.
    let id: ObjectIdentifier
    let regain: @MainActor () -> Void
}

@MainActor
final class FocusedSessionStore {
    private struct HeldClaim {
        let claim: FocusedSessionContext
        let holder: FocusClaimHolder
    }

    private(set) var focused: FocusedSessionContext?
    private var focusedHolder: FocusClaimHolder?
    /// Superseded claims on the focused session that their runtimes have not
    /// released yet, oldest first. Each runtime releases its claim on teardown
    /// (`forget`), so a destroyed chat never regains focus. A claim on another
    /// session drops them all: a background chat must re-appear to claim again.
    private var heldClaims: [HeldClaim] = []
    private var generation = 0

    /// Route commands to `sessionId`. Re-routing to the already focused session
    /// keeps its context so an owner's claim survives routine re-binds
    /// (stream open, re-entry); a different session gets a new context.
    @discardableResult
    func focus(sessionId: String) -> FocusedSessionContext {
        if let focused, focused.sessionId == sessionId {
            return focused
        }
        return claim(sessionId: sessionId)
    }

    /// Start a new ownership claim for `sessionId`, even if it is already
    /// focused. Any older claim on the same session stops matching; with a
    /// `holder` it is kept so `handBack(from:)` can return focus to it.
    @discardableResult
    func claim(sessionId: String, holder: FocusClaimHolder? = nil) -> FocusedSessionContext {
        if let focused, focused.sessionId == sessionId {
            if let focusedHolder {
                heldClaims.append(HeldClaim(claim: focused, holder: focusedHolder))
            }
        } else {
            heldClaims.removeAll()
        }
        if let holder {
            heldClaims.removeAll { $0.holder.id == holder.id }
        }
        generation += 1
        let context = FocusedSessionContext(
            sessionId: sessionId,
            generation: generation
        )
        focused = context
        focusedHolder = holder
        return context
    }

    /// Release the current `claim` to the newest held claim on the same
    /// session and return that claim's holder. Nil when `claim` is not current
    /// or no held claim is left; focus is unchanged then.
    func handBack(from claim: FocusedSessionContext) -> FocusClaimHolder? {
        guard focused == claim, let next = heldClaims.popLast() else { return nil }
        focused = next.claim
        focusedHolder = next.holder
        return next.holder
    }

    /// Drop a superseded claim its runtime released; it can never regain focus.
    func forget(_ claim: FocusedSessionContext) {
        heldClaims.removeAll { $0.claim == claim }
    }

    func clear() {
        focused = nil
        focusedHolder = nil
        heldClaims.removeAll()
    }

    func isFocused(_ sessionId: String) -> Bool {
        focused?.sessionId == sessionId
    }

    func isCurrent(_ claim: FocusedSessionContext) -> Bool {
        focused == claim
    }
}
