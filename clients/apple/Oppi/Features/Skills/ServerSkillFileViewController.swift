import UIKit

/// How a Skill file opens. Every file is read from its host path, the same
/// direct read as any other host file.
enum ServerSkillFilePresentation: Equatable {
    /// Readable, with the editor and Edit with Oppi.
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

/// One Skill file in the shared file viewer (route `.serverSkillFile`), on the
/// Skill's server. The Skill's page or the catalog already holds its summary,
/// so opening a file is one host read; the server rebuilds its Skill catalog
/// only when neither has it. An editable Skill's own file opens with the
/// selected-text review flow, the editor, and Edit with Oppi; other files are
/// read-only. The file's bar items show in this screen's bar.
@MainActor
final class ServerSkillFileViewController: UIViewController {
    let target: ServerSkillFileNavTarget

    private enum Shown: Equatable {
        case connecting
        case loading
        case unavailable(String)
        case file(ServerSkillFilePresentation)
    }

    private let root: AppRootEnvironment
    /// The route makes the Skill's server the active one on every appearance.
    private let switchesServer: Bool
    /// The Skill's server once it is ready.
    private var connection: ServerConnection? {
        didSet { setNeedsUpdateProperties() }
    }
    private var fetchedSummary: ServerSkillSummary? {
        didSet { setNeedsUpdateProperties() }
    }
    private var error: String? {
        didSet { setNeedsUpdateProperties() }
    }
    private var shown: Shown?
    private var content: UIViewController?
    private var connectTask: Task<Void, Never>?
    private var summaryTask: Task<Void, Never>?
    private var isOnScreen = false

    /// `connection`: the Skill's server when the caller already has it ready;
    /// nil makes it the active server first ("Connecting…").
    init(target: ServerSkillFileNavTarget, root: AppRootEnvironment, connection: ServerConnection? = nil) {
        self.target = target
        self.root = root
        self.connection = connection
        switchesServer = connection == nil
        super.init(nibName: nil, bundle: nil)
        traitOverrides.appRootEnvironment = root
        navigationItem.largeTitleDisplayMode = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        connectTask?.cancel()
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
        // The server switch and the summary load run on every appearance,
        // as the hosted screen's tasks did.
        if switchesServer {
            connect()
        } else {
            loadSummaryIfNeeded()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        isOnScreen = false
        connectTask?.cancel()
        connectTask = nil
        summaryTask?.cancel()
        summaryTask = nil
    }

    override func updateProperties() {
        super.updateProperties()
        view.backgroundColor = root.themeStore.backgroundColor
        guard let connection else {
            show(.connecting)
            updateBar()
            return
        }
        if let summary = summary(in: connection) {
            show(.file(ServerSkillFilePresentation.resolve(
                editable: summary.editable,
                resourcePath: summary.path,
                selectedFilePath: target.path
            )), summary: summary, connection: connection)
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

    private func connect() {
        connectTask?.cancel()
        let coordinator = root.coordinator
        let serverId = target.serverId
        connectTask = Task { [weak self] in
            guard await coordinator.switchToServerReady(serverId), !Task.isCancelled, let self else { return }
            self.connection = coordinator.connection(for: serverId)
            self.loadSummaryIfNeeded()
        }
    }

    private func loadSummaryIfNeeded() {
        guard isOnScreen, let connection, summary(in: connection) == nil else { return }
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

    private func show(_ next: Shown, summary: ServerSkillSummary? = nil, connection: ServerConnection? = nil) {
        guard shown != next else { return }
        shown = next
        removeContent()
        switch next {
        case .connecting:
            contentUnavailableConfiguration = loadingConfiguration(String(localized: "Connecting…"))
        case .loading:
            contentUnavailableConfiguration = loadingConfiguration(String(localized: "Loading file…"))
        case .unavailable(let reason):
            contentUnavailableConfiguration = unavailableConfiguration(reason)
        case .file(.unavailable(let reason)):
            contentUnavailableConfiguration = unavailableConfiguration(reason)
        case .file(.editable(let hostPath)):
            contentUnavailableConfiguration = nil
            guard let summary, let connection else { return }
            embed(ReviewableControlMarkdownViewController(
                hostFilePath: hostPath,
                serverId: target.serverId,
                title: target.path,
                skillFile: SkillFileEditTarget(skillId: target.resourceId, path: target.path),
                domain: .skills,
                targetId: target.resourceId,
                targetName: summary.name,
                sourceLabel: "\(summary.name) / \(target.path)",
                editFlow: .guidedRevision,
                connection: connection
            ))
        case .file(.readOnly(let hostPath)):
            contentUnavailableConfiguration = nil
            guard let connection else { return }
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

    private func loadingConfiguration(_ text: String) -> UIContentUnavailableConfiguration {
        var loading = UIContentUnavailableConfiguration.loading()
        loading.text = text
        loading.background.backgroundColor = root.themeStore.backgroundColor
        return loading
    }

    private func unavailableConfiguration(_ reason: String) -> UIContentUnavailableConfiguration {
        var unavailable = UIContentUnavailableConfiguration.empty()
        unavailable.image = UIImage(systemName: "exclamationmark.triangle.fill")
        unavailable.text = String(localized: "File Unavailable")
        unavailable.secondaryText = reason
        var retry = UIButton.Configuration.borderedProminent()
        retry.title = String(localized: "Retry")
        unavailable.button = retry
        unavailable.buttonProperties.primaryAction = UIAction { [weak self] _ in
            guard let self, let connection = self.connection else { return }
            self.loadSummary(connection)
        }
        unavailable.background.backgroundColor = root.themeStore.backgroundColor
        return unavailable
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
            navigationItem.title = shown == .connecting ? nil : fileName
            navigationItem.rightBarButtonItems = nil
        }
    }
}
