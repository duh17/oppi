import UIKit

/// How a Skill file opens. Every file is read from its host path, the same
/// direct read as any other host file.
enum ServerSkillFilePresentation: Equatable {
    /// Readable, with the editor and Edit with Session.
    case editable(hostPath: String)
    case readOnly(hostPath: String)
    /// No host path to read.
    case unavailable(reason: String)

    static func resolve(
        editable: Bool,
        resourcePath: String?,
        selectedFilePath: String
    ) -> Self {
        guard let resourcePath else {
            return .unavailable(reason: "The server did not provide this Skill’s source path.")
        }
        guard let location = hostLocation(
            resourcePath: resourcePath,
            selectedFilePath: selectedFilePath
        ) else {
            return .unavailable(reason: "This file does not have a valid Skill-relative path.")
        }
        return editable && location.isSkillSource
            ? .editable(hostPath: location.path)
            : .readOnly(hostPath: location.path)
    }

    /// `isSkillSource` is false for a file beside a top-level Markdown Skill:
    /// that Skill is the one file, so revising it never edits its neighbors.
    private static func hostLocation(
        resourcePath: String,
        selectedFilePath: String
    ) -> (path: String, isSkillSource: Bool)? {
        let components = selectedFilePath.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard resourcePath.hasPrefix("/"),
              !resourcePath.contains("\0"),
              !selectedFilePath.isEmpty,
              !selectedFilePath.contains("\0"),
              !selectedFilePath.contains("\\"),
              !selectedFilePath.hasPrefix("/"),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return nil
        }

        let canonicalResourcePath = (resourcePath as NSString).standardizingPath
        let resourceFileName = (canonicalResourcePath as NSString).lastPathComponent
        let skillDirectory: String
        var isSkillSource = true
        if resourceFileName == "SKILL.md" {
            skillDirectory = (canonicalResourcePath as NSString).deletingLastPathComponent
        } else if canonicalResourcePath.hasSuffix(".md") {
            skillDirectory = (canonicalResourcePath as NSString).deletingLastPathComponent
            isSkillSource = selectedFilePath == resourceFileName
        } else {
            skillDirectory = canonicalResourcePath
        }
        let path = ((skillDirectory as NSString).appendingPathComponent(selectedFilePath) as NSString)
            .standardizingPath
        return (path, isSkillSource)
    }
}

/// One Skill file in the shared file viewer, on the Skill's server: a host file
/// whose server-named edit origin is a Skill (`HostFileScreen`). The Skill's page or the catalog already holds its summary,
/// so opening a file is one host read; the server rebuilds its Skill catalog
/// only when neither has it. An editable Skill's own file opens with the
/// selected-text review flow, the editor, and Edit with Session; other files
/// are read-only. The file's bar items show in this screen's bar.
@MainActor
final class ServerSkillFileViewController: UIViewController {
    let target: ServerSkillFileNavTarget

    private enum Shown: Equatable {
        case loading
        case unavailable(String)
        case file(ServerSkillFilePresentation)
    }

    private let root: AppRootEnvironment
    /// The Skill's server.
    private let connection: ServerConnection
    private var fetchedSummary: ServerSkillSummary? {
        didSet { setNeedsUpdateProperties() }
    }
    private var error: String? {
        didSet { setNeedsUpdateProperties() }
    }
    private var shown: Shown?
    private var content: UIViewController?
    private var summaryTask: Task<Void, Never>?
    private var isOnScreen = false

    init(target: ServerSkillFileNavTarget, root: AppRootEnvironment, connection: ServerConnection) {
        self.target = target
        self.root = root
        self.connection = connection
        super.init(nibName: nil, bundle: nil)
        traitOverrides.appRootEnvironment = root
        navigationItem.largeTitleDisplayMode = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        summaryTask?.cancel()
    }

    private var fileName: String {
        target.path.split(separator: "/").last.map(String.init) ?? target.path
    }

    // MARK: Lifecycle

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(true, animated: animated)
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        isOnScreen = true
        loadSummaryIfNeeded()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        isOnScreen = false
        summaryTask?.cancel()
        summaryTask = nil
    }

    override func updateProperties() {
        super.updateProperties()
        view.backgroundColor = root.themeStore.backgroundColor
        if let summary = summary(in: connection) {
            show(.file(ServerSkillFilePresentation.resolve(
                editable: summary.editable,
                resourcePath: summary.path,
                selectedFilePath: target.path
            )), summary: summary)
        } else if let error {
            show(.unavailable(error))
        } else {
            show(.loading)
        }
        updateBar()
    }

    /// The fetched summary, else the Skill's page detail, else the catalog row.
    private func summary(in connection: ServerConnection) -> ServerSkillSummary? {
        let store = connection.serverResourceStore
        return fetchedSummary
            ?? store.skillDetail(id: target.resourceId, serverId: target.serverId)?.summary
            ?? store.skills(forServer: target.serverId).first { $0.id == target.resourceId }
    }

    private func loadSummaryIfNeeded() {
        guard isOnScreen, summary(in: connection) == nil else { return }
        loadSummary(connection)
    }

    private func loadSummary(_ connection: ServerConnection) {
        summaryTask?.cancel()
        summaryTask = Task { [weak self] in
            guard let self else { return }
            error = nil
            guard let apiClient = connection.apiClient else {
                error = "Not connected"
                return
            }
            do {
                let detail = try await apiClient.getServerSkill(id: target.resourceId)
                guard !Task.isCancelled else { return }
                connection.serverResourceStore.rememberSkillDetail(detail, serverId: target.serverId)
                fetchedSummary = detail.summary
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
        }
    }

    // MARK: Content

    private func show(_ next: Shown, summary: ServerSkillSummary? = nil) {
        guard shown != next else { return }
        shown = next
        removeContent()
        switch next {
        case .loading:
            contentUnavailableConfiguration = loadStateConfiguration(.loading(String(localized: "Loading file…")))
        case .unavailable(let reason), .file(.unavailable(let reason)):
            contentUnavailableConfiguration = loadStateConfiguration(.failed(
                title: String(localized: "File Unavailable"),
                message: reason,
                retry: RetryAction { [weak self] in
                    guard let self else { return }
                    self.loadSummary(self.connection)
                }
            ))
        case .file(.editable(let hostPath)):
            contentUnavailableConfiguration = nil
            guard let summary else { return }
            embed(ReviewableControlMarkdownViewController(
                hostFilePath: hostPath,
                serverId: target.serverId,
                title: target.path,
                skillFile: SkillFileEditTarget(skillId: target.resourceId, path: target.path),
                domain: .skills,
                targetId: target.resourceId,
                targetName: summary.name,
                sourceLabel: "\(summary.name) / \(target.path)",
                connection: connection
            ))
        case .file(.readOnly(let hostPath)):
            contentUnavailableConfiguration = nil
            embed(FileViewerViewController(
                configuration: .init(
                    workspaceId: "",
                    serverId: target.serverId,
                    filePath: hostPath,
                    fileName: fileName,
                    title: target.path,
                    source: .hostFile
                ),
                services: .init(connection: connection)
            ))
        }
    }

    private func loadStateConfiguration(_ state: LoadState) -> UIContentUnavailableConfiguration {
        .loadState(state, palette: ThemeRuntimeState.currentPalette(), background: root.themeStore.backgroundColor)
    }

    private func embed(_ controller: UIViewController) {
        addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.topAnchor.constraint(equalTo: view.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        controller.didMove(toParent: self)
        content = controller
    }

    private func removeContent() {
        guard let content else { return }
        content.willMove(toParent: nil)
        content.view.removeFromSuperview()
        content.removeFromParent()
        self.content = nil
    }

    // MARK: Bar

    /// The file's bar while it shows; the file name before.
    private func updateBar() {
        let bar = (content as? FileViewerViewController)?.bar
            ?? (content as? ReviewableControlMarkdownViewController)?.fileViewer?.bar
        if let bar {
            bar.apply(to: navigationItem)
        } else {
            navigationItem.title = fileName
            navigationItem.rightBarButtonItems = nil
        }
    }
}
