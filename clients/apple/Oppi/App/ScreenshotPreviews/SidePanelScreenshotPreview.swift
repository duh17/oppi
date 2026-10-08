#if DEBUG
import Foundation
import SwiftUI

/// Hosts the file browser, commit review, and workspace review surfaces with
/// in-memory fixtures so Duo and iPad screenshots do not need a paired server.
struct SidePanelScreenshotPreview: View {
    enum Surface {
        case files
        case commit
        case review
    }

    let surface: Surface

    @State private var navigation = AppNavigation()
    @State private var sessionStore = SessionStore()
    @State private var fileIndexStore = FileIndexStore()

    private let apiClient = SidePanelScreenshotAPI.makeClient()

    var body: some View {
        NavigationStack {
            switch surface {
            case .files:
                FileBrowserView(
                    serverId: "preview-server",
                    workspaceId: SidePanelScreenshotAPI.workspaceId,
                    initialPath: "",
                    opensFirstFileForPreview: true
                )
            case .commit:
                CommitDetailView(
                    workspaceId: SidePanelScreenshotAPI.workspaceId,
                    commit: GitCommitSummary(
                        sha: SidePanelScreenshotAPI.sha,
                        message: "feat: open side content from the trailing edge",
                        date: "2026-10-08T18:00:00Z"
                    ),
                    opensFirstFileForPreview: true
                )
            case .review:
                WorkspaceReviewFileDetailView(
                    workspaceId: SidePanelScreenshotAPI.workspaceId,
                    selectedSessionId: nil,
                    file: SidePanelScreenshotAPI.reviewFiles[0],
                    navigationFiles: SidePanelScreenshotAPI.reviewFiles
                )
            }
        }
        .environment(navigation)
        .environment(sessionStore)
        .environment(fileIndexStore)
        .environment(WorkspaceStore())
        .environment(\.apiClient, apiClient)
        .preferredColorScheme(.dark)
        .task {
            ScreenshotPreviewOrientation.applyRequested()
        }
        .accessibilityIdentifier("screenshot.ready")
    }
}

private enum SidePanelScreenshotAPI {
    static let host = "side-panel-preview.oppi"
    static let workspaceId = "preview-workspace"
    static let sha = "d30b40337"

    static let reviewFiles: [WorkspaceReviewFile] = [
        WorkspaceReviewFile(
            path: "clients/apple/Oppi/Features/FileBrowser/FileBrowserView.swift",
            status: "M",
            addedLines: 12,
            removedLines: 4,
            isStaged: false,
            isUnstaged: true,
            isUntracked: false,
            selectedSessionTouched: true
        ),
        WorkspaceReviewFile(
            path: "clients/apple/Oppi/Features/Review/CommitDetailView.swift",
            status: "M",
            addedLines: 8,
            removedLines: 1,
            isStaged: false,
            isUnstaged: true,
            isUntracked: false,
            selectedSessionTouched: true
        ),
    ]

    static func makeClient() -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SidePanelScreenshotURLProtocol.self]
        let baseURL = URL(string: "https://\(host)") ?? URL(fileURLWithPath: "/")
        return APIClient(baseURL: baseURL, token: "preview-token", configuration: config)
    }
}

private final class SidePanelScreenshotURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == SidePanelScreenshotAPI.host
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
        if path.contains("/git/commits/") && path.contains("/diff") {
            response = json(Self.commitDiffJSON())
        } else if path.contains("/git/commits/") {
            response = json(Self.commitDetailJSON())
        } else if path.contains("/git/diff") {
            response = json(Self.reviewDiffJSON(query: url.query ?? ""))
        } else if path.contains("/quick-actions") {
            response = json(["actions": []])
        } else if path.contains("/paths") {
            response = json(Self.fileIndexJSON())
        } else if path.contains("/raw/") {
            let filePath = path.split(separator: "/raw/").last.map(String.init) ?? "file"
            response = (200, "text/plain", Data("// Preview \(filePath)\nlet ready = true\n".utf8))
        } else if path.contains("/contents") {
            response = json(Self.directoryJSON())
        } else {
            response = json(["error": "Not found", "path": path], status: 404)
        }

        guard let http = HTTPURLResponse(
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
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func directoryJSON() -> [String: Any] {
        [
            "path": "/",
            "entries": [
                ["name": "FileBrowserView.swift", "type": "file", "size": 4200, "modifiedAt": 1_800_000_000_000],
                ["name": "CommitDetailView.swift", "type": "file", "size": 3100, "modifiedAt": 1_800_000_000_000],
                ["name": "clients", "type": "directory", "size": 0, "modifiedAt": 1_800_000_000_000],
            ],
            "truncated": false,
        ]
    }

    private static func fileIndexJSON() -> [String: Any] {
        [
            "paths": [
                "FileBrowserView.swift",
                "CommitDetailView.swift",
            ],
            "truncated": false,
        ]
    }

    private static func commitDetailJSON() -> [String: Any] {
        [
            "sha": SidePanelScreenshotAPI.sha,
            "message": "feat: open side content from the trailing edge",
            "date": "2026-10-08T18:00:00Z",
            "author": "Chen",
            "files": [
                ["path": "clients/apple/Oppi/Features/FileBrowser/FileBrowserView.swift", "status": "M", "addedLines": 12, "removedLines": 4],
                ["path": "clients/apple/Oppi/Features/Review/CommitDetailView.swift", "status": "M", "addedLines": 8, "removedLines": 1],
            ],
            "addedLines": 20,
            "removedLines": 5,
        ]
    }

    private static func commitDiffJSON() -> [String: Any] {
        diffJSON(path: "clients/apple/Oppi/Features/FileBrowser/FileBrowserView.swift")
    }

    private static func reviewDiffJSON(query: String) -> [String: Any] {
        let filePath = query.split(separator: "path=").last.map(String.init) ?? "file.swift"
        return diffJSON(path: filePath.removingPercentEncoding ?? filePath)
    }

    private static func diffJSON(path: String) -> [String: Any] {
        [
            "workspaceId": SidePanelScreenshotAPI.workspaceId,
            "path": path,
            "baselineText": "let layout = width >= 700\n",
            "currentText": "let layout = sizeClass == .regular\n",
            "addedLines": 1,
            "removedLines": 1,
            "hunks": [
                [
                    "oldStart": 1,
                    "oldCount": 1,
                    "newStart": 1,
                    "newCount": 1,
                    "lines": [
                        ["kind": "removed", "text": "let layout = width >= 700", "oldLine": 1, "newLine": NSNull(), "spans": NSNull()],
                        ["kind": "added", "text": "let layout = sizeClass == .regular", "oldLine": NSNull(), "newLine": 1, "spans": NSNull()],
                    ],
                ],
            ],
        ]
    }

    private func json(_ object: Any, status: Int = 200) -> (status: Int, contentType: String, body: Data) {
        let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return (status, "application/json", body)
    }
}
#endif
