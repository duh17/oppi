#if DEBUG
import UIKit

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

    /// The review screen's neighbors: one changed file each.
    static var reviewFiles: [WorkspaceReviewFile] {
        files.map {
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
    }
}

/// Which screen a motion capture shows. Both sit in a router stack between two
/// neighbor files.
enum FileBrowserMotionPreviewMode {
    /// The file viewer as a tree pane.
    case fileBrowser
    /// The review screen, whose quick-action chat the files feed.
    case review
}

/// `SCREENSHOT_SCREEN=file-browser-motion` / `review-file-motion`: the real
/// screen at the root of a router stack, over the fixture files, in the dark
/// theme the captures pin (`.preferredColorScheme(.dark)`). The strip along the
/// bottom edge reports the host's Reduce Motion setting, the UIKit form of the
/// `\.accessibilityReduceMotion` the SwiftUI wrapper read, so a capture pair
/// shows both the plain and the reduced transition.
final class FileBrowserMotionPreviewController: PreviewRootController {
    // The services the screens push and play with, held as long as the preview
    // the way the SwiftUI view's `@State` held them.
    private let connection: ServerConnection
    private let navigation: AppNavigation
    /// Reports the host's Reduce Motion setting: the UIKit form of the
    /// `@Environment(\.accessibilityReduceMotion)` the SwiftUI wrapper read.
    private let readout = UILabel()

    init(mode: FileBrowserMotionPreviewMode) {
        ScreenshotVolatileDefaults.applyDarkTheme(true)
        let connection = ServerConnection()
        let navigation = AppNavigation()
        self.connection = connection
        self.navigation = navigation
        let root = AppRootEnvironment.preview(
            coordinator: ConnectionCoordinator(serverStore: ServerStore()),
            navigation: navigation
        )
        let apiClient = FileBrowserMotionPreviewSupport.makeClient()
        let files = FileBrowserMotionPreviewSupport.files
        let reviewFiles = FileBrowserMotionPreviewSupport.reviewFiles
        super.init(
            root: root,
            themeStore: root.themeStore,
            content: PreviewHost.screenStack(root: root) {
                switch mode {
                case .fileBrowser:
                    let middle = files[1]
                    return FileViewerViewController(
                        configuration: .init(
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
                        ),
                        services: .init(apiClient: apiClient)
                    )
                case .review:
                    return WorkspaceReviewFileDetailViewController(
                        configuration: .init(
                            workspaceId: FileBrowserMotionPreviewSupport.workspaceId,
                            selectedSessionId: nil,
                            file: reviewFiles[1],
                            navigationFiles: reviewFiles
                        ),
                        connection: connection,
                        apiClient: apiClient,
                        navigation: navigation
                    )
                }
            }
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // A readout, not a control: the screen under it keeps its taps. The
        // captures match its label, the way the SwiftUI `Text` carried it.
        readout.backgroundColor = .themeBlue
        readout.font = .monospacedSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .caption2).pointSize,
            weight: .regular
        )
        readout.textColor = .themeOnBlue
        readout.textAlignment = .center
        readout.isUserInteractionEnabled = false
        readout.accessibilityIdentifier = "file.motion.reduceMotion"
        readout.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(readout)
        NSLayoutConstraint.activate([
            readout.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            readout.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            readout.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applyReduceMotion),
            name: UIAccessibility.reduceMotionStatusDidChangeNotification,
            object: nil
        )
        applyReduceMotion()
    }

    /// Follows the setting live, as the environment read did.
    @objc private func applyReduceMotion() {
        let text = UIAccessibility.isReduceMotionEnabled ? "reduce-motion-on" : "reduce-motion-off"
        readout.text = text
        readout.accessibilityLabel = text
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

        if path == "/files/current" {
            let filePath = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "path" })?.value ?? ""
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
