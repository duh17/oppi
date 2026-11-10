#if DEBUG
import Foundation

/// `CHAT_ROUTES_NATIVE_WIDGET_FILE=<path>`: a version 1 native widget, as a server publishes it in
/// an `extension_ui_notification`, read from a JSON file `{ "widgetKey", "statusText"?,
/// "nativeSurface" }`. A screenshot can then show the surface a real server builds (for example
/// the classic background-jobs list from `backgroundPill`) without a paired server.
enum ChatRoutesNativeWidget {
    private struct Document: Decodable {
        let widgetKey: String
        let statusText: String?
        let nativeSurface: ExtensionUINativeSurface
    }

    static func notifications(path: String) -> [ExtensionUINotification] {
        guard let data = FileManager.default.contents(atPath: path),
              let document = try? JSONDecoder().decode(Document.self, from: data) else { return [] }
        return [
            ExtensionUINotification(
                method: "setStatus", message: nil, notifyType: nil, statusKey: document.widgetKey,
                statusText: document.statusText, title: nil, text: nil, widgetKey: nil, widgetLines: nil,
                widgetPlacement: nil
            ),
            ExtensionUINotification(
                method: "setWidget", message: nil, notifyType: nil, statusKey: nil, statusText: nil,
                title: nil, text: nil, widgetKey: document.widgetKey, widgetLines: [], widgetPlacement: nil,
                nativeSurface: document.nativeSurface
            ),
        ]
    }
}
#endif
