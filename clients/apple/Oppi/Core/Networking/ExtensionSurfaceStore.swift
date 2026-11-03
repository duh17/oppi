import Foundation

/// One session's extension surfaces, observed on their own. A busy session
/// can change its working text every second (an elapsed timer), and only the
/// timeline's working row shows that text, so it lives in its own property.
/// The chat screen reads `layout`, which changes only when an extension
/// changes a status, widget, title, or the working row's visibility or
/// indicator.
@MainActor @Observable
final class SessionExtensionSurface {
    /// The whole surface. Views read `layout` and `workingMessage`, derived from it.
    @ObservationIgnored private(set) var state = ExtensionSurfaceState()
    /// Every surface except the working text: `working?.message` is always nil.
    private(set) var layout = ExtensionSurfaceState()
    private(set) var workingMessage: String?
    /// The composable surface action waiting on the server, if one is. It is interaction state,
    /// not surface state: the publisher never sees it and the next frame clears it.
    private(set) var pendingAction: ExtensionSurfacePendingAction?

    func replace(with state: ExtensionSurfaceState) {
        self.state = state.hasRetainedContent ? state : ExtensionSurfaceState()
        var layout = self.state
        layout.working?.message = nil
        if layout.working?.isDefault == true { layout.working = nil }
        // Observation fires on every assignment, equal or not.
        if self.layout != layout { self.layout = layout }
        let message = self.state.working?.message
        if workingMessage != message { workingMessage = message }
    }

    func beginAction(_ action: ExtensionSurfacePendingAction) {
        if pendingAction != action { pendingAction = action }
    }

    /// `extension_ui_settled` names the request that ended, whatever the action drew.
    func settle(requestId: String) {
        guard pendingAction?.requestId == requestId else { return }
        pendingAction = nil
    }

    /// A frame newer than the revision the action was sent at is the answer: the declared pending
    /// words belong to the round trip and nothing longer.
    func dropPending(surfaceId: String, whenNewerThan revision: Int) {
        guard let pending = pendingAction,
              pending.surfaceId == surfaceId,
              revision > pending.revision else {
            return
        }
        pendingAction = nil
    }

    func clearPending() {
        if pendingAction != nil { pendingAction = nil }
    }
}

/// Extension surfaces by session. Each session's `SessionExtensionSurface`
/// is observed on its own, so one session's update redraws only views that
/// read that session.
@MainActor
final class ExtensionSurfaceStore {
    private var surfaces: [String: SessionExtensionSurface] = [:]

    /// Created on first read and cleared in place, never removed: a view that
    /// already observes it would miss a replacement.
    func surface(for sessionId: String) -> SessionExtensionSurface {
        if let surface = surfaces[sessionId] { return surface }
        let surface = SessionExtensionSurface()
        surfaces[sessionId] = surface
        return surface
    }

    func apply(_ notification: ExtensionUINotification, sessionId: String) {
        let surface = surface(for: sessionId)
        var state = surface.state
        ExtensionSurfaceReducer.apply(notification, to: &state)
        surface.replace(with: state)
    }

    /// A published composable surface: replace by id, then end a pending action it answers.
    func apply(_ published: ExtensionUISurface, sessionId: String) {
        let surface = surface(for: sessionId)
        var state = surface.state
        ExtensionSurfaceReducer.apply(published, to: &state)
        surface.replace(with: state)
        surface.dropPending(surfaceId: published.id, whenNewerThan: published.revision)
    }

    func apply(_ patch: ExtensionUISurfacePatch, sessionId: String) {
        let surface = surface(for: sessionId)
        var state = surface.state
        ExtensionSurfaceReducer.apply(patch, to: &state)
        surface.replace(with: state)
        surface.dropPending(surfaceId: patch.surfaceId, whenNewerThan: patch.revision)
    }

    func beginAction(_ action: ExtensionSurfacePendingAction, sessionId: String) {
        surface(for: sessionId).beginAction(action)
    }

    func settle(requestId: String, sessionId: String) {
        surface(for: sessionId).settle(requestId: requestId)
    }

    func clear(sessionId: String) {
        let surface = surface(for: sessionId)
        surface.replace(with: ExtensionSurfaceState())
        surface.clearPending()
    }
}
