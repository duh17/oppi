import Foundation

/// The wire names a client uses to tell a server what it can draw.
///
/// The value is carried by the `client_capabilities` message a client sends beside its session
/// subscription: the server binds that message to the session stream, and a client that never
/// sends one keeps receiving the v1 projection. The iPhone and iPad app sends
/// `extensionNativeUIComposites` on every session socket it opens to a server that lists the same
/// capability, so its surfaces arrive as composites.
enum ClientCapability {
    /// `extension-native-ui:v2:composites`: this build draws `extension_ui_surface` and answers
    /// `extension_ui_action` (`ExtensionSurfaceCompositeViews`, `ExtensionSurfaceStore`).
    ///
    /// `ServerConnection.routeStreamMessage` sends this list on `stream_connected`, as the server
    /// begins replaying the session's surfaces; it declares again on every socket open, so a
    /// reconnect or a switch to another focused session is covered. A server that does not
    /// advertise it is never sent the command. The Mac app does not send it and keeps the v1
    /// projection.
    static let extensionNativeUIComposites = "extension-native-ui:v2:composites"
}
