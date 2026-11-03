import Foundation

/// The wire names a client uses to tell a server what it can draw.
///
/// The value is carried by the `client_capabilities` message a client sends beside its session
/// subscription: the server binds that message to the session stream, and a client that never
/// sends one keeps receiving the v1 projection. Nothing sends this value yet, so every surface
/// still arrives as v1 blocks.
enum ClientCapability {
    /// `extension-native-ui:v2:composites`: this build draws `extension_ui_surface` and answers
    /// `extension_ui_action` (`ExtensionSurfaceCompositeViews`, `ExtensionSurfaceStore`).
    ///
    /// The message belongs next to the focused session subscription — `ServerConnection.connectStream()`
    /// opens the session socket and `handleConnected(_:)` (`ServerConnection+MessageRouter.swift`) is
    /// where the client first knows the stream is live. Adding this id to that message's list, and
    /// the matching server binding, is the whole switch.
    static let extensionNativeUIComposites = "extension-native-ui:v2:composites"
}
