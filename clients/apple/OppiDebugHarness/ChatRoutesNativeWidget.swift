#if DEBUG
import Foundation

/// `CHAT_ROUTES_NATIVE_WIDGET_FILE=<path>`: a version 1 native widget, as a server publishes it in
/// an `extension_ui_notification`, read from a JSON file `{ "widgetKey", "statusText"?,
/// "nativeSurface" }`. A screenshot can then show the surface a real server builds (for example
/// the classic background-jobs list from `backgroundPill`) without a paired server.
/// `CHAT_ROUTES_SURFACE=subagents` publishes `subagentsJSON` the same way.
enum ChatRoutesNativeWidget {
    private struct Document: Decodable {
        let widgetKey: String
        let statusText: String?
        let nativeSurface: ExtensionUINativeSurface
    }

    static func notifications(path: String) -> [ExtensionUINotification] {
        FileManager.default.contents(atPath: path).map(notifications(data:)) ?? []
    }

    static func notifications(data: Data) -> [ExtensionUINotification] {
        guard let document = try? JSONDecoder().decode(Document.self, from: data) else { return [] }
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

    /// The Subagents widget as `server/plugins/subagents` publishes it for one working child (a
    /// long step line) and two finished ones: a Working and a Recent section of activity rows.
    static var subagentsJSON: Data {
        let since = Int(Date().timeIntervalSince1970 * 1000) - 9_000
        return Data(subagentsTemplate.replacingOccurrences(of: "__SINCE__", with: String(since)).utf8)
    }

    private static let subagentsTemplate = #"""
{
  "widgetKey": "subagents",
  "statusText": "1 working",
  "nativeSurface": {
    "version": 1,
    "id": "widget:subagents",
    "source": "widget",
    "presentation": { "style": "surfacePanel", "title": "Subagents", "subtitle": "1 working" },
    "blocks": [
      {
        "type": "section", "id": "subagents:working", "title": "Working",
        "blocks": [{
          "type": "activityList", "id": "subagents:working:rows",
          "rows": [{
            "id": "a1", "title": "codemode-row",
            "subtitle": "read ~/.config/oppi/worktrees/main/wt_subagent-codemode-row/clients/apple/Oppi/Features/Chat",
            "detail": "opus-5-5 medium", "state": "running", "link": "oppi://session/a1", "since": __SINCE__
          }]
        }]
      },
      {
        "type": "section", "id": "subagents:recent", "title": "Recent",
        "blocks": [{
          "type": "activityList", "id": "subagents:recent:rows",
          "rows": [
            {
              "id": "a2", "title": "table-view",
              "subtitle": "The gate failure is fixed, and the new tip is **`efc0a1b`** with every lane green",
              "detail": "opus-5-5 high · $51.82 · 26 ahead · took 17m", "state": "success", "link": "oppi://session/a2"
            },
            {
              "id": "a3", "title": "markdown-glue-2",
              "subtitle": "Both items and both cleanups are done, rebased onto main and ready to land",
              "detail": "opus-5-5 high · $37.99 · 7 ahead · took 25m", "state": "success", "link": "oppi://session/a3"
            }
          ]
        }]
      }
    ],
    "fallback": { "lines": ["codemode-row", "table-view", "markdown-glue-2"] }
  }
}
"""#
}
#endif
