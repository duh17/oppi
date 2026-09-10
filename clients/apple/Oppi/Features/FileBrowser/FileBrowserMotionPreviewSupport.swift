#if DEBUG
import Foundation
import SwiftUI

enum FileBrowserMotionPreviewSupport {
    static let workspaceId = "preview-motion"
    static let host = "preview-motion.oppi"

    static let files: [(path: String, name: String, marker: String)] = [
        ("motion/alpha.md", "alpha.md", "FILE_MOTION_ALPHA"),
        ("motion/beta.md", "beta.md", "FILE_MOTION_BETA"),
        ("motion/gamma.md", "gamma.md", "FILE_MOTION_GAMMA"),
    ]

    static func makeClient() -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FileBrowserMotionPreviewURLProtocol.self]
        let baseURL = URL(string: "https://\(host)") ?? URL(fileURLWithPath: "/")
        return APIClient(baseURL: baseURL, token: "preview-token", configuration: config)
    }

    static func body(for path: String, marker: String) -> String {
        """
        # \(marker)

        Identifiable \(path) page for previous/next file motion.
        """
    }
}

struct FileBrowserMotionPreview: View {
    private let apiClient = FileBrowserMotionPreviewSupport.makeClient()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let files = FileBrowserMotionPreviewSupport.files
        let middle = files[1]
        NavigationStack {
            FileBrowserContentView(
                workspaceId: FileBrowserMotionPreviewSupport.workspaceId,
                filePath: middle.path,
                fileName: middle.name,
                fileSize: 240,
                chromeMode: .treePane,
                navigationContext: FileBrowserNavigationContext(
                    files: files.map {
                        FileBrowserSelection(path: $0.path, name: $0.name, size: 240)
                    }
                )
            )
        }
        .environment(\.apiClient, apiClient)
        .preferredColorScheme(.dark)
        .overlay(alignment: .bottom) {
            FileBrowserMotionReduceMotionReadout(reduceMotion: reduceMotion)
        }
        .accessibilityIdentifier("screenshot.ready")
    }
}

struct ReviewFileMotionPreview: View {
    private let apiClient = FileBrowserMotionPreviewSupport.makeClient()
    @State private var sessionStore = SessionStore()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let files = FileBrowserMotionPreviewSupport.files.map {
            WorkspaceReviewFile(
                path: $0.path,
                status: "M",
                addedLines: 1,
                removedLines: 1,
                isStaged: false,
                isUnstaged: true,
                isUntracked: false,
                selectedSessionTouched: true
            )
        }
        NavigationStack {
            WorkspaceReviewFileDetailView(
                workspaceId: FileBrowserMotionPreviewSupport.workspaceId,
                selectedSessionId: nil,
                file: files[1],
                navigationFiles: files
            )
        }
        .environment(sessionStore)
        .environment(\.apiClient, apiClient)
        .preferredColorScheme(.dark)
        .overlay(alignment: .bottom) {
            FileBrowserMotionReduceMotionReadout(reduceMotion: reduceMotion)
        }
        .accessibilityIdentifier("screenshot.ready")
    }
}

private struct FileBrowserMotionReduceMotionReadout: View {
    let reduceMotion: Bool

    var body: some View {
        Text(reduceMotion ? "reduce-motion-on" : "reduce-motion-off")
            .font(.caption2.monospaced())
            .foregroundStyle(.themeOnBlue)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(.themeBlue)
            .accessibilityIdentifier("file.motion.reduceMotion")
            .accessibilityValue(reduceMotion ? "on" : "off")
            .accessibilityLabel(reduceMotion ? "reduce-motion-on" : "reduce-motion-off")
    }
}

private final class FileBrowserMotionPreviewURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == FileBrowserMotionPreviewSupport.host
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        let response: (status: Int, contentType: String, body: Data)
        let path = url.path

        if path.hasPrefix("/workspaces/\(FileBrowserMotionPreviewSupport.workspaceId)/raw/") {
            let filePath = String(path.dropFirst("/workspaces/\(FileBrowserMotionPreviewSupport.workspaceId)/raw/".count))
            if let file = FileBrowserMotionPreviewSupport.files.first(where: { $0.path == filePath }) {
                let body = FileBrowserMotionPreviewSupport.body(for: file.path, marker: file.marker)
                response = (200, "text/plain; charset=utf-8", Data(body.utf8))
            } else {
                response = json(["error": "Not found", "path": filePath], status: 404)
            }
        } else if path.hasPrefix("/workspaces/\(FileBrowserMotionPreviewSupport.workspaceId)/git/diff") {
            let filePath = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "path" })?
                .value
            if let filePath,
               let file = FileBrowserMotionPreviewSupport.files.first(where: { $0.path == filePath }) {
                response = json(diffJSON(for: file.path, marker: file.marker))
            } else {
                response = json(["error": "Not found"], status: 404)
            }
        } else if path.hasPrefix("/workspaces/\(FileBrowserMotionPreviewSupport.workspaceId)/quick-actions") {
            response = json(["actions": []])
        } else {
            response = json(["error": "Not found", "path": path], status: 404)
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

    private func json(_ object: Any, status: Int = 200) -> (status: Int, contentType: String, body: Data) {
        let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return (status, "application/json", body)
    }

    private func diffJSON(for path: String, marker: String) -> [String: Any] {
        [
            "workspaceId": FileBrowserMotionPreviewSupport.workspaceId,
            "path": path,
            "baselineText": "old \(marker)",
            "currentText": FileBrowserMotionPreviewSupport.body(for: path, marker: marker),
            "addedLines": 1,
            "removedLines": 1,
            "hunks": [
                [
                    "oldStart": 1,
                    "oldCount": 1,
                    "newStart": 1,
                    "newCount": 1,
                    "lines": [
                        [
                            "kind": "removed",
                            "text": "old \(marker)",
                            "oldLine": 1,
                        ],
                        [
                            "kind": "added",
                            "text": marker,
                            "newLine": 1,
                        ],
                    ],
                ],
            ],
        ]
    }
}
#endif
