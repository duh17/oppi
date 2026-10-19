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

    func clear(sessionId: String) {
        surfaces[sessionId]?.replace(with: ExtensionSurfaceState())
    }
}
