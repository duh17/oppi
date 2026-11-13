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
    /// advertise it is never sent the command.
    static let extensionNativeUIComposites = "extension-native-ui:v2:composites"

    /// `extension-native-ui:v2:blocks`: this build also draws a `blocks` section's tree of
    /// primitives and a composed pill. A client that names only `composites` is sent the v1
    /// projection of any surface that uses a tree, because one frame cannot mix the two shapes.
    static let extensionNativeUIBlocks = "extension-native-ui:v2:blocks"

    /// `extension-native-ui:v2:elapsed`: this build ticks an `elapsed` node itself and draws a
    /// pill's text at the strip's size (`ExtensionSurfaceBlockMetrics.font`). A client that names
    /// `blocks` without it is sent each elapsed node as static text, because a build that predates
    /// the node draws it as unsupported, and a pill's `headline` as `caption`, because it draws a
    /// pill's `headline` at a card title's size.
    static let extensionNativeUIElapsed = "extension-native-ui:v2:elapsed"

    /// `extension-native-ui:v2:panel`: this build opens a surface in a pane beside its chat
    /// (`ExtensionPanelViewController`), reads a surface's `panel` hints, and draws a `panel`
    /// placement's pill as the way into that pane. A client that does not name it is sent each
    /// surface without the hints and placed as `strip`.
    static let extensionNativeUIPanel = "extension-native-ui:v2:panel"

    /// `extension-native-ui:v2:working`: this build draws an `icon` node named `working` as the
    /// app's static working icon (`BlocksIconView`). A client that does not name it is sent a
    /// symbol in its place.
    static let extensionNativeUIWorking = "extension-native-ui:v2:working"
}
