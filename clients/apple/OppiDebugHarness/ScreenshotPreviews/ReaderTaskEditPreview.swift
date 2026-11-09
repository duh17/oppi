#if DEBUG
import CryptoKit
import UIKit

/// `SCREENSHOT_SCREEN=reader-task-edit`: the file viewer on a fixture workspace
/// whose files live on the simulator's disk, behind the real `APIClient`
/// (`/server/info`, `GET` and `PUT /files/current` with `If-Match`). A save goes
/// through the app's own edit path and lands in a real file, and the readout
/// strip shows what that file holds, so a UI test checks the bytes on disk.
///
/// `OPPI_READER_TASK_FILE` picks the file (`tasks.org` by default, `notebook.org`,
/// or `notes.md`), and `OPPI_READER_TASK_LONG=1` adds a screenful of prose and a
/// last task under the Org seed. "Change file on disk" is a second writer, for
/// the conflict path.
enum ReaderTaskEditFixture {
    static let workspaceId = "preview-tasks"
    static let host = "preview-tasks.oppi"

    static let orgSeed = """
    #+TODO: TODO NEXT WAIT | DONE CANCELLED

    * NEXT [#A] Ship the reader [1/3] :oppi:
    SCHEDULED: <2026-11-11 Wed +1w>
    - [ ] Toggle a checkbox
    - [X] Pick a date
    - [ ] Change a state

    * TODO Write the notes
    DEADLINE: <2026-11-20 Fri>

    * Plain heading
    Some prose.
    """

    /// A notebook-style file for heading folds: three levels, drawers, links.
    static let notebookSeed = """
    #+TITLE: Oppi project
    #+TODO: TODO NEXT WAIT | DONE CANCELLED

    * NEXT [#A] Ship Org rendering [1/3] :oppi:ios:
    SCHEDULED: <2026-11-11 Wed> DEADLINE: <2026-11-13 Fri>
    :PROPERTIES:
    :ID: 3f2a9c1e-7b64-4d0a-9d1e-0c5a2b7e8f10
    :END:
    Parser, converter and reader. See [[file:release.org::*Checklist][the release checklist]].
    - [X] Parse planning lines
    - [ ] Render progress cookies
    ** DONE Draft the brief :oppi:
    CLOSED: [2026-11-06 Fri 14:00]
    Scope was agreed in the planning thread.
    ** WAIT Device check [40%]
    SCHEDULED: <2026-11-12 Thu>
    Waiting on a simulator slot.
    *** TODO Record the screenshots
    - [ ] iPhone
    - [ ] iPad mini
    ** CANCELLED Retire the old extension
    CLOSED: [2026-11-05 Thu 09:30]
    * TODO Write the release notes
    DEADLINE: <2026-11-20 Fri>
    :PROPERTIES:
    :ID: 9d1c4e7a-2b08-4c63-8a5f-6e3b1d0f7a22
    :END:
    Draft after the device check.
    * Notes
    - No dev install until Wednesday.
    - See [[*Ship Org rendering][the task above]] and [[https://example.com][the docs]].
    - [ ] Review the screenshots
    """

    /// A long notebook-style file for heading navigation: a title, drawers with
    /// IDs, four levels, TODO states, and links to its own headings.
    static var handbookSeed: String {
        func section(_ n: Int) -> String {
            (1...3).map { "Paragraph \($0) of section \(n): notes, decisions and the occasional link, long enough to fill a phone screen with prose." }
                .joined(separator: "\n\n")
        }
        var text = """
        #+TITLE: Handbook
        #+TODO: TODO NEXT WAIT | DONE CANCELLED

        * Index
        Jump to:
        - [[*Deep dive][Go to the deep dive]]
        - [[id:5b0c7d2e-4f1a-4a5e-9c3d-1e2f3a4b5c6d][Go to the shipping plan]]
        - [[#release-notes][Go to the release notes]]
        - [[*Missing heading][A heading that is gone]]

        """
        text += "* NEXT Planning\n\(section(1))\n\n** DONE Goals\n\(section(2))\n\n"
        text += "** WAIT Shipping plan\n:PROPERTIES:\n:ID: 5b0c7d2e-4f1a-4a5e-9c3d-1e2f3a4b5c6d\n:END:\n\(section(3))\n\n"
        text += "*** TODO Deep dive\n\(section(4))\n\n**** Details\n\(section(5))\n\n"
        text += "* Research\n\(section(6))\n\n** Prior art\n\(section(7))\n\n"
        text += "* TODO Release notes :oppi:\n:PROPERTIES:\n:CUSTOM_ID: release-notes\n:END:\n\(section(8))\n\n"
        text += "* Appendix\n\(section(9))\n"
        return text
    }

    static let flatSeed = "Just prose, with no headings at all.\n\nA second paragraph.\n"

    static let markdownSeed = """
    # Release plan [1/3]

    - [ ] Tag the build
    - [x] Write the notes
    - [ ] Ask for review
      - [ ] Reviewer one
    """

    static var fileName: String {
        ProcessInfo.processInfo.environment["OPPI_READER_TASK_FILE"] ?? "tasks.org"
    }

    /// Where the fixture "server" keeps its files; a new directory every launch.
    nonisolated(unsafe) static var directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("reader-task-edit-\(UUID().uuidString)", isDirectory: true)

    nonisolated static func url(for name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    static func seed() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var org = orgSeed
        if ProcessInfo.processInfo.environment["OPPI_READER_TASK_LONG"] == "1" {
            // A task far down the page, for the reading position across a save.
            org += (1...60).map { "\n\nParagraph \($0) of filler prose that makes the file long enough to scroll." }.joined()
            org += "\n\n* TODO Bottom\n- [ ] bottom box\n- [ ] second box"
        }
        try? Data(org.utf8).write(to: url(for: "tasks.org"), options: .atomic)
        try? Data(notebookSeed.utf8).write(to: url(for: "notebook.org"), options: .atomic)
        try? Data(markdownSeed.utf8).write(to: url(for: "notes.md"), options: .atomic)
        try? Data(handbookSeed.utf8).write(to: url(for: "handbook.org"), options: .atomic)
        try? Data(flatSeed.utf8).write(to: url(for: "flat.org"), options: .atomic)
    }

    static func makeClient() -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ReaderTaskEditURLProtocol.self]
        let baseURL = URL(string: "https://\(host)") ?? URL(fileURLWithPath: "/")
        return APIClient(baseURL: baseURL, token: "preview-token", configuration: config)
    }

    nonisolated static func etag(of data: Data) -> String {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return "\"sha256-\(digest)\""
    }
}

/// The edit routes of the real server, over files on disk.
final class ReaderTaskEditURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    /// `OPPI_READER_TASK_READONLY=1`: a server that does not edit workspace files.
    private static var serverInfo: Data {
        let editing = ProcessInfo.processInfo.environment["OPPI_READER_TASK_READONLY"] == "1"
            ? "" : #","workspaceFileEditing":{"version":1,"maxBytes":1048576}"#
        let json = #"{"name":"preview","version":"1.0","uptime":1,"os":"darwin","arch":"arm64","hostname":"preview","nodeVersion":"22","piVersion":"1","configVersion":1,"capabilities":{"currentFiles":{"version":1}"# + editing + #"},"stats":{"workspaceCount":1,"activeSessionCount":0,"totalSessionCount":0,"skillCount":0,"modelCount":0}}"#
        return Data(json.utf8)
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        switch (request.httpMethod ?? "GET", url.path) {
        case ("GET", "/server/info"):
            respond(200, ["Content-Type": "application/json"], Self.serverInfo)
        case ("GET", "/files/current"):
            guard let file = file(in: url), let data = try? Data(contentsOf: file) else {
                respond(404, [:], Data(#"{"error":"missing"}"#.utf8))
                return
            }
            respond(200, ["Content-Type": "text/plain", "ETag": ReaderTaskEditFixture.etag(of: data)], data)
        case ("PUT", "/files/current"):
            write(to: url)
        default:
            respond(404, [:], Data(#"{"error":"missing"}"#.utf8))
        }
    }

    private func file(in url: URL) -> URL? {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let path = items.first(where: { $0.name == "path" })?.value,
              !path.contains("/"), !path.contains("..") else { return nil }
        return ReaderTaskEditFixture.url(for: path)
    }

    /// The server's own rule: the write lands only when `If-Match` names the
    /// version on disk.
    private func write(to url: URL) {
        guard let file = file(in: url), let current = try? Data(contentsOf: file) else {
            respond(404, [:], Data(#"{"error":"missing"}"#.utf8))
            return
        }
        guard request.value(forHTTPHeaderField: "If-Match") == ReaderTaskEditFixture.etag(of: current) else {
            respond(412, [:], Data(#"{"error":"stale"}"#.utf8))
            return
        }
        let body = request.httpBody ?? Self.readStream(request.httpBodyStream)
        do {
            try body.write(to: file, options: .atomic)
        } catch {
            respond(500, [:], Data(#"{"error":"write failed"}"#.utf8))
            return
        }
        let etag = ReaderTaskEditFixture.etag(of: body).replacingOccurrences(of: "\"", with: "\\\"")
        respond(200, ["Content-Type": "application/json"], Data(#"{"etag":"\#(etag)","size":\#(body.count),"mtimeMs":1}"#.utf8))
    }

    private func respond(_ status: Int, _ headers: [String: String], _ body: Data) {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func readStream(_ stream: InputStream?) -> Data {
        guard let stream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

final class ReaderTaskEditPreviewController: PreviewRootController {
    /// What the file holds on disk, read each time it is asked for.
    private let readout = UILabel()
    private let fileName = ReaderTaskEditFixture.fileName
    private var timer: Timer?

    init() {
        // The dark default holds unless the capture names a theme.
        ScreenshotVolatileDefaults.applyThemeScheme(ProcessInfo.processInfo.environment["SCREENSHOT_COLOR_SCHEME"])
        ReaderTaskEditFixture.seed()
        let root = AppRootEnvironment.preview(
            coordinator: ConnectionCoordinator(serverStore: ServerStore()),
            navigation: AppNavigation()
        )
        let client = ReaderTaskEditFixture.makeClient()
        let name = ReaderTaskEditFixture.fileName
        let viewer = PreviewLoadingController(
            // The viewer reads the server's capabilities before it offers an edit.
            prepare: { _ = try? await client.serverInfo() },
            content: {
                PreviewHost.screenStack(root: root) {
                    FileViewerViewController(
                        configuration: .init(
                            workspaceId: ReaderTaskEditFixture.workspaceId,
                            serverId: "preview-server",
                            filePath: name,
                            fileName: name,
                            chromeMode: .treePane
                        ),
                        services: .init(apiClient: client)
                    )
                }
            }
        )
        super.init(root: root, themeStore: root.themeStore, content: viewer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        readout.font = .monospacedSystemFont(ofSize: 2, weight: .regular)
        readout.numberOfLines = 0
        readout.textColor = .clear
        readout.isUserInteractionEnabled = false
        readout.isAccessibilityElement = true
        readout.accessibilityIdentifier = "diag.readerTask.disk"
        readout.translatesAutoresizingMaskIntoConstraints = false

        // A second writer: the file changes on disk behind the reader's back.
        let change = UIButton(type: .system)
        change.setTitle("Change file on disk", for: .normal)
        change.titleLabel?.font = .preferredFont(forTextStyle: .caption2)
        change.accessibilityIdentifier = "harness.readerTask.changeDisk"
        change.translatesAutoresizingMaskIntoConstraints = false
        change.addAction(UIAction { [fileName] _ in
            let file = ReaderTaskEditFixture.url(for: fileName)
            let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            try? Data((text + "\nChanged elsewhere.\n").utf8).write(to: file, options: .atomic)
        }, for: .touchUpInside)

        view.addSubview(readout)
        view.addSubview(change)
        NSLayoutConstraint.activate([
            readout.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            readout.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            readout.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            // Bottom-leading: the top trailing corner is the reader's bar.
            change.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            change.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])
        refreshReadout()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshReadout() }
        }
    }

    isolated deinit {
        timer?.invalidate()
    }

    private func refreshReadout() {
        let text = (try? String(contentsOf: ReaderTaskEditFixture.url(for: fileName), encoding: .utf8)) ?? ""
        if readout.accessibilityValue != text {
            readout.accessibilityValue = text
            readout.text = text
        }
        readout.accessibilityLabel = "On disk: \(fileName)"
    }
}
#endif
