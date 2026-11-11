#if DEBUG
import UIKit

/// `SCREENSHOT_SCREEN=file-browser-column`: the workspace File Browser route
/// (the real `FileBrowserViewController`) over a fixture server, opened on a
/// long Org file in `projects/`. Regular width shows the folder tree beside the
/// file, with the tree's toggle in the bar; compact width shows the file alone.
enum FileBrowserColumnFixture {
    static let workspaceId = "notebook"
    static let host = "file-browser-column.invalid"
    static let openFile = FileBrowserSelection(path: "projects/garden.org", name: "garden.org", size: 9_800)

    /// The workspace's folders, as `/workspaces/notebook/contents[/<folder>]` lists them.
    static let listings: [String: [(name: String, isDirectory: Bool, size: Int)]] = [
        "": [
            ("journal", true, 0), ("notes", true, 0), ("projects", true, 0),
            ("inbox.org", false, 2_310), ("index.org", false, 4_120), ("README.md", false, 860),
        ],
        "projects/": [
            ("archive", true, 0),
            ("bike-commute.org", false, 3_400), ("garden.org", false, 9_800),
            ("home-network.org", false, 5_120), ("reading-list.org", false, 2_700),
            ("tax-2026.org", false, 1_940),
        ],
    ]

    static var indexPaths: [String] {
        listings.flatMap { folder, entries in
            entries.filter { !$0.isDirectory }.map { folder + $0.name }
        }.sorted()
    }

    /// A season's garden notebook: headings, planning lines, drawers, lists,
    /// tables, and links, long enough to scroll several screens.
    static let gardenOrg: String = {
        var text = """
        #+TITLE: Garden 2026
        #+TODO: TODO NEXT WAIT | DONE CANCELLED

        * Overview
        Raised beds along the south fence, the herb spiral by the kitchen door,
        and two fruit trees that finally look settled. This file is the season's
        plan, the log of what went in the ground, and the list of things to fix
        before the first frost.

        * NEXT [#A] Spring planting [2/5] :beds:
        SCHEDULED: <2026-03-21 Sat>
        :PROPERTIES:
        :ID: 7c1d2e3f-4a5b-4c6d-8e7f-9a0b1c2d3e4f
        :END:
        - [X] Turn the compost into bed 1 and bed 2
        - [X] Start tomatoes and peppers indoors
        - [ ] Direct-sow peas along the trellis
        - [ ] Plant out lettuce once nights stay above 5 °C
        - [ ] Mulch the strawberries

        ** DONE Order seeds
        CLOSED: [2026-02-02 Mon 19:40]
        Ordered from the usual co-op. Kept last year's beans; they germinated well.

        ** WAIT Soil test results
        Sent two samples in late February. The lab says three to four weeks.

        * Beds
        | Bed | Size    | This year         | Last year      |
        |-----+---------+-------------------+----------------|
        |   1 | 1.2 × 3 | Tomatoes, basil   | Beans          |
        |   2 | 1.2 × 3 | Beans, squash     | Brassicas      |
        |   3 | 1.2 × 2 | Brassicas, onions | Tomatoes       |
        |   4 | 0.8 × 2 | Salad, radishes   | Salad          |

        """
        let months = ["April", "May", "June", "July", "August", "September", "October"]
        for (index, month) in months.enumerated() {
            text += """

            * \(month) log
            ** Week \(index * 4 + 1)
            Watered twice; the rain barrel ran dry by Thursday. The early lettuce is
            ready to thin, and the peas have found the trellis on their own. Slugs
            took two of the squash seedlings, so a beer trap went in by bed 2.

            ** Week \(index * 4 + 3)
            Harvested a first bowl of greens. The tomatoes needed tying in after the
            wind, and the basil is ready to pinch out. Noted for next year: sow the
            second round of carrots a fortnight earlier than this.
            - [X] Tie in the tomatoes
            - [ ] Top up the mulch on bed \(index % 4 + 1)

            """
        }
        text += """

        * TODO Before the first frost
        DEADLINE: <2026-10-25 Sun>
        - [ ] Lift the last of the potatoes
        - [ ] Cover bed 3 with fleece
        - [ ] Drain and store the hoses
        - [ ] Clean and oil the tools

        * Notes
        - Rotation follows [[file:../notes/rotation.org][the four-bed rotation]].
        - The herb spiral wants full sun; move the mint into a pot.
        - Last line of the file: if this sits under the floating buttons, the
          reader's bottom inset is too small.
        """
        return text
    }()

    static func makeClient() -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FileBrowserColumnURLProtocol.self]
        let baseURL = URL(string: "https://\(host)") ?? URL(fileURLWithPath: "/")
        return APIClient(baseURL: baseURL, token: "preview-token", configuration: config)
    }
}

/// The routes the browser and its viewer read: folder listings, the file index,
/// and the open file's text. Everything else is a 404.
final class FileBrowserColumnURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == FileBrowserColumnFixture.host
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let workspace = "/workspaces/\(FileBrowserColumnFixture.workspaceId)"
        var contentType = "application/json"
        let body: Data?
        switch (request.httpMethod ?? "GET", url.path) {
        case ("GET", "\(workspace)/contents"):
            body = Self.listing("")
        case ("GET", "\(workspace)/contents/projects"):
            body = Self.listing("projects/")
        case ("GET", "\(workspace)/paths"):
            body = try? JSONSerialization.data(withJSONObject: [
                "paths": FileBrowserColumnFixture.indexPaths,
                "truncated": false,
            ])
        case ("GET", "/files/current"):
            contentType = "text/plain"
            body = Data(FileBrowserColumnFixture.gardenOrg.utf8)
        default:
            body = nil
        }
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: body == nil ? 404 : 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": contentType]
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body ?? Data(#"{"error":"Not found"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func listing(_ folder: String) -> Data? {
        let entries = (FileBrowserColumnFixture.listings[folder] ?? []).map { entry -> [String: Any] in
            [
                "name": entry.name,
                "path": folder + entry.name + (entry.isDirectory ? "/" : ""),
                "type": entry.isDirectory ? "directory" : "file",
                "size": entry.size,
                "modifiedAt": 1_790_000_000_000,
            ]
        }
        return try? JSONSerialization.data(withJSONObject: ["path": folder, "entries": entries, "truncated": false])
    }
}

final class FileBrowserColumnPreviewController: PreviewRootController {
    init() {
        ScreenshotVolatileDefaults.applyThemeScheme(ProcessInfo.processInfo.environment["SCREENSHOT_COLOR_SCHEME"])
        let coordinator = ConnectionCoordinator(serverStore: ServerStore())
        let root = AppRootEnvironment.preview(coordinator: coordinator)
        // Launched, as the window's shell is, so the keyboard commands answer.
        root.navigation.revealPairedServerShell()
        guard let server = PairedServer(from: ServerCredentials(
            host: FileBrowserColumnFixture.host,
            port: 7749,
            token: "sk_preview",
            name: "mac-studio",
            scheme: .https,
            serverFingerprint: "sha256:file-browser-column",
            tlsCertFingerprint: "sha256:file-browser-column-leaf"
        )) else {
            preconditionFailure("file browser column preview server")
        }
        coordinator.serverStore.replaceServersForPreview([server])
        let connection = coordinator.activatePreviewServer(server, apiClient: FileBrowserColumnFixture.makeClient())
        connection.workspaceStore.upsert(Workspace(
            id: FileBrowserColumnFixture.workspaceId,
            name: "notebook",
            description: nil,
            icon: .symbol("book.closed"),
            systemPrompt: nil,
            hostMount: "~/notebook",
            gitStatusEnabled: false,
            createdAt: Date(timeIntervalSince1970: 1_770_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_770_000_000)
        ), serverId: server.id)
        let target = FileBrowserNavTarget(
            serverId: server.id,
            scope: .workspace(workspaceId: FileBrowserColumnFixture.workspaceId, worktreeId: nil),
            path: "",
            columnDirectoryPath: "projects/",
            columnSelectedFile: FileBrowserColumnFixture.openFile
        )
        super.init(
            root: root,
            themeStore: root.themeStore,
            content: PreviewHost.screenStack(root: root) {
                FileBrowserViewController(root: root, target: target, showsSidebarToggle: false)
            }
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}
#endif
