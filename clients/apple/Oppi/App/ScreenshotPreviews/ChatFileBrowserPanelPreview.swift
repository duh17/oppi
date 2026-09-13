#if DEBUG
import Foundation
import SwiftUI
import UIKit

// MARK: - Chat File Browser Panel Preview

struct ChatFileBrowserPanelPreview: View {
    @State private var selectedTab = ScreenshotPreviewConfig.panelTab
    @State private var navigation = AppNavigation()
    @State private var gitStatusStore = GitStatusStore()
    @State private var fileIndexStore = FileIndexStore()

    private let apiClient = ScreenshotPreviewFileBrowserAPI.makeClient()

    private static let sessionId = "preview-session"
    private static let workspaceId = "preview-workspace"

    private static let changedFiles = [
        "clients/apple/Oppi/Features/Chat/ChatView.swift",
        "clients/apple/Oppi/Features/Chat/Support/SessionFiles/ChatFileBrowserPanel.swift",
        "clients/apple/Oppi/Features/FileBrowser/FileBrowserView.swift",
        "clients/apple/OppiTests/FileBrowser/ChatFileBrowserPanelTests.swift",
    ]

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let style = ChatFileBrowserPanelLayout.style(for: size)

            Group {
                switch style {
                case .sideRail:
                    let panelWidth = ChatFileBrowserPanelLayout.sideRailWidth(for: size)
                    HStack(spacing: 0) {
                        previewSessionColumn
                            .frame(width: max(0, size.width - panelWidth), height: size.height)

                        Divider().overlay(Color.themeComment.opacity(0.18))

                        panel
                            .frame(width: panelWidth, height: size.height)
                    }
                case .bottomPanel:
                    let panelHeight = ChatFileBrowserPanelLayout.bottomPanelHeight(for: size)
                    VStack(spacing: 0) {
                        previewSessionColumn
                            .frame(width: size.width, height: max(0, size.height - panelHeight))

                        Divider().overlay(Color.themeComment.opacity(0.18))

                        panel
                            .frame(width: size.width, height: panelHeight)
                    }
                }
            }
            .frame(width: size.width, height: size.height)
        }
        .background(Color.themeBg.ignoresSafeArea())
        .environment(navigation)
        .environment(gitStatusStore)
        .environment(fileIndexStore)
        .environment(WorkspaceStore())
        .environment(ReviewCommentStore())
        .environment(QuickCommentTemplateStore())
        .environment(VoiceInputManager())
        .environment(AskRequestStore())
        .environment(MessageQueueStore())
        .environment(\.apiClient, apiClient)
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("screenshot.ready")
    }

    private var panel: some View {
        NavigationStack {
            ChatFileBrowserPanel(
                sessionId: Self.sessionId,
                workspaceId: Self.workspaceId,
                changedFiles: Self.changedFiles,
                selectedTab: $selectedTab
            )
            .navigationTitle("Files")
            .navigationBarTitleDisplayMode(.inline)
        }
        .accessibilityIdentifier("chat-file-panel.preview")
    }

    private var previewSessionColumn: some View {
        VStack(spacing: 0) {
            previewToolbar
            Divider().overlay(Color.themeComment.opacity(0.18))
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    previewBubble(role: "You", text: "Please split chat so I can review changed files and browse the whole workspace without leaving the session.")
                    previewToolRow(tool: "edit", path: "clients/apple/Oppi/Features/Chat/ChatView.swift", stats: "+72 −0")
                    previewToolRow(tool: "write", path: "clients/apple/Oppi/Features/Chat/Support/SessionFiles/ChatFileBrowserPanel.swift", stats: "+220")
                    previewBubble(role: "Oppi", text: "Added a chat-attached file surface with Changed and All modes. The selected mode is remembered per session.")
                }
                .padding(16)
            }
            .background(Color.themeBgDark)
            previewComposer
        }
    }

    private var previewToolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: "chevron.left")
                .font(.headline.weight(.semibold))
                .frame(width: 44, height: 44)
                .background(Color.themeBgHighlight.opacity(0.75), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text("Research First M…")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.themeFg)
                Text("Actual session preview · $39.68")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.themeComment)
            }

            Spacer(minLength: 8)

            Image(systemName: "folder.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.themeBlue)
                .frame(width: 40, height: 40)
                .background(Color.themeBgHighlight.opacity(0.75), in: Circle())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.themeBg)
    }

    private func previewBubble(role: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(role)
                .font(.caption.bold())
                .foregroundStyle(role == "You" ? .themeBlue : .themePurple)
            Text(text)
                .font(.body)
                .foregroundStyle(.themeFg)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.themeBg.opacity(0.9), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func previewToolRow(tool: String, path: String, stats: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "terminal")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.themeCyan)
                .frame(width: 26, height: 26)
                .background(Color.themeCyan.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(tool)
                    .font(.caption.bold())
                    .foregroundStyle(.themeFg)
                Text(path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.themeComment)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            Text(stats)
                .font(.caption2.monospaced().bold())
                .foregroundStyle(.themeDiffAdded)
        }
        .padding(12)
        .background(Color.themeBg.opacity(0.74), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var previewComposer: some View {
        HStack(spacing: 8) {
            Text("Ask about these files…")
                .font(.body)
                .foregroundStyle(.themeComment)
            Spacer()
            Image(systemName: "arrow.up.circle.fill")
                .font(.title3)
                .foregroundStyle(.themeBlue)
        }
        .padding(.horizontal, 14)
        .frame(height: 58)
        .background(Color.themeBg)
    }
}


private enum ScreenshotPreviewFileBrowserAPI {
    static func makeClient() -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ScreenshotPreviewFileBrowserURLProtocol.self]
        let baseURL = URL(string: "https://preview.oppi") ?? URL(fileURLWithPath: "/")
        return APIClient(
            baseURL: baseURL,
            token: "preview-token",
            configuration: config
        )
    }
}


private final class ScreenshotPreviewFileBrowserURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "preview.oppi"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        let path = url.path
        let response: (status: Int, contentType: String, body: Data)

        switch path {
        case "/workspaces/preview-workspace/sessions/preview-session/changes":
            response = jsonResponse(Self.sessionChangesJSON)
        case "/workspaces/preview-workspace/paths":
            response = jsonResponse(Self.fileIndexJSON)
        case "/workspaces/preview-workspace/contents", "/workspaces/preview-workspace/contents/":
            response = jsonResponse(Self.rootDirectoryJSON)
        case "/workspaces/preview-workspace/contents/clients", "/workspaces/preview-workspace/contents/clients/":
            response = jsonResponse(Self.clientsDirectoryJSON)
        case "/workspaces/preview-workspace/contents/clients/apple", "/workspaces/preview-workspace/contents/clients/apple/":
            response = jsonResponse(Self.appleDirectoryJSON)
        case let rawPath where rawPath.hasPrefix("/workspaces/preview-workspace/raw/"):
            let filePath = String(rawPath.dropFirst("/workspaces/preview-workspace/raw/".count))
            let body = "// Preview content for \(filePath)\n".data(using: .utf8) ?? Data()
            response = (200, "text/plain", body)
        default:
            response = jsonResponse(["error": "Not found", "path": path], status: 404)
        }

        guard let httpResponse = HTTPURLResponse(
            url: url,
            statusCode: response.status,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": response.contentType,
                "Content-Length": "\(response.body.count)",
            ]
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static let changedPaths = [
        "clients/apple/Oppi/Features/Chat/ChatView.swift",
        "clients/apple/Oppi/Features/Chat/Support/SessionFiles/ChatFileBrowserPanel.swift",
        "clients/apple/Oppi/Features/FileBrowser/FileBrowserView.swift",
        "clients/apple/OppiTests/FileBrowser/ChatFileBrowserPanelTests.swift",
    ]

    private static var sessionChangesJSON: [String: Any] {
        [
            "workspaceId": "preview-workspace",
            "sessionId": "preview-session",
            "files": changedPaths.map { ["path": $0] },
            "changedFileCount": changedPaths.count,
            "changedFilesOverflow": 0,
        ]
    }

    private static var fileIndexJSON: [String: Any] {
        [
            "paths": changedPaths + [
                "README.md",
                "server/src/routes/workspace-files.ts",
                "server/src/routes/session-files.ts",
                "clients/apple/Oppi/App/ScreenshotPreviewView.swift",
            ],
            "truncated": false,
        ]
    }

    private static var rootDirectoryJSON: [String: Any] {
        [
            "path": "/",
            "entries": [
                ["name": "clients", "type": "directory", "size": 0, "modifiedAt": 1_800_000_000_000],
                ["name": "server", "type": "directory", "size": 0, "modifiedAt": 1_800_000_000_000],
                ["name": "README.md", "type": "file", "size": 18_420, "modifiedAt": 1_800_000_000_000],
            ],
            "truncated": false,
        ]
    }

    private static var clientsDirectoryJSON: [String: Any] {
        [
            "path": "clients/",
            "entries": [
                ["name": "apple", "type": "directory", "size": 0, "modifiedAt": 1_800_000_000_000],
            ],
            "truncated": false,
        ]
    }

    private static var appleDirectoryJSON: [String: Any] {
        [
            "path": "clients/apple/",
            "entries": [
                ["name": "Oppi", "type": "directory", "size": 0, "modifiedAt": 1_800_000_000_000],
                ["name": "OppiTests", "type": "directory", "size": 0, "modifiedAt": 1_800_000_000_000],
                ["name": "project.yml", "type": "file", "size": 22_111, "modifiedAt": 1_800_000_000_000],
            ],
            "truncated": false,
        ]
    }

    private func jsonResponse(
        _ object: Any,
        status: Int = 200
    ) -> (status: Int, contentType: String, body: Data) {
        let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return (status, "application/json", body)
    }
}


private extension ScreenshotPreviewConfig {
    static var panelTab: ChatFileBrowserPanelTab {
        let raw = ProcessInfo.processInfo.environment["SCREENSHOT_PANEL_TAB"]
        return raw.flatMap(ChatFileBrowserPanelTab.init(rawValue:)) ?? .changed
    }
}
#endif
