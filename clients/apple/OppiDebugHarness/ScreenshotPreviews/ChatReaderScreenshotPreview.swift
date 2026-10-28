#if DEBUG
import Foundation
import UIKit

/// Fixture services and payloads for `ChatReaderScreenshotPreview` (the
/// `chat-reader-*`, `server-lock-cover`, and `now-playing-player` screens).
@MainActor
enum ChatReaderScreenshotFixture {
    /// The chat a preview reader pretends to come from. It is never locked.
    static let origin = ScopedLockTarget.server("sha256:chat-reader-preview-origin")

    static let servers: [PairedServer] = ["mac-studio", "mac-mini"].compactMap { name in
        PairedServer(from: ServerCredentials(
            host: "\(name).local",
            port: 7749,
            token: "sk_preview",
            name: name,
            scheme: .https,
            serverFingerprint: "sha256:chat-reader-preview-\(name)",
            tlsCertFingerprint: "sha256:chat-reader-preview-\(name)-leaf"
        ))
    }

    static func makeRoot() -> AppRootEnvironment {
        switch ProcessInfo.processInfo.environment["SCREENSHOT_COLOR_SCHEME"] {
        case "dark": ScreenshotVolatileDefaults.applyTheme(.dark)
        case "light": ScreenshotVolatileDefaults.applyTheme(.light)
        default: break
        }
        let coordinator = ConnectionCoordinator(serverStore: ServerStore())
        coordinator.serverStore.replaceServersForPreview(servers)
        if let first = servers.first { _ = coordinator.switchToServer(first) }
        return .preview(coordinator: coordinator)
    }

    static func reader(root: AppRootEnvironment, payload: ChatReaderPayload) -> ChatReaderViewController {
        ChatReaderViewController(target: root.chatReaderPayloadStore.store(payload), root: root)
    }

    static var documentPayload: ChatReaderPayload {
        ChatReaderPayload(
            kind: .document(content: .markdown(
                content: """
                # Reader preview

                A document opened from the timeline, with a paragraph long enough to wrap onto a second line at the \
                larger text sizes, and a list:

                - the back control sits in the reader's own bar
                - the page reaches under the status bar
                - the stack's bar stays hidden
                """,
                filePath: "docs/reader-preview.md"
            )),
            lockOrigin: origin
        )
    }

    static var extensionPayload: ChatReaderPayload {
        let base = { (id: String) in ExtensionUIBlockBase(id: id, accessibility: nil) }
        let surface = ExtensionUINativeSurface(
            version: 1,
            id: "widget:jobs",
            source: "widget",
            presentation: ExtensionUINativePresentation(style: "surfacePanel", title: "Jobs", subtitle: "3 running"),
            blocks: [
                .markdown(base: base("summary"), markdown: "**3** jobs running, 1 waiting on input."),
                .activityList(base: base("rows"), rows: [
                    ExtensionUIActivityRow(
                        id: "build", title: "Build the release", subtitle: "Compiling targets", detail: "42s",
                        state: "active", progress: 0.6, link: nil, children: nil
                    ),
                    ExtensionUIActivityRow(
                        id: "tests", title: "Run the unit suites", subtitle: nil, detail: "1m 10s",
                        state: "active", progress: nil, link: nil, children: nil
                    ),
                    ExtensionUIActivityRow(
                        id: "lint", title: "Lint", subtitle: "Waiting on input", detail: nil,
                        state: "inactive", progress: nil, link: nil, children: nil
                    ),
                ]),
            ],
            fallback: nil
        )
        return .extensionNative(ExtensionNativeReaderContent(
            surface: surface,
            identifierSuffix: "jobs",
            title: "Jobs",
            subtitle: "3 running",
            statusText: nil
        ))
    }
}
#endif
