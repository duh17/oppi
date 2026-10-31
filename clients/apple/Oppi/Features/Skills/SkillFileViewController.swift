import UIKit
import os.log

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "SkillFile")

/// One file of a skill directory, pushed from `SkillDetailViewController`:
/// text shows in the full-screen reader (syntax-highlighted code or Markdown)
/// with its own floating Back, so the stack's bar hides while it shows. While
/// the file loads, or when it fails, the bar shows the file's name.
///
/// The file is fetched on the presenting screen's server, with the same
/// project folder (`cwd`) the skill was listed for.
@MainActor
final class SkillFileViewController: UIViewController, NavigationBarHiding {
    private enum Phase: Equatable {
        case loading
        case failed(String)
        case loaded(String)
    }

    private let skillName: String
    private let filePath: String
    private let cwd: String?
    private let connection: ServerConnection
    private let root: AppRootEnvironment
    private let reviewCommentSelectionScope: ReviewCommentSelectionScope?

    private var phase = Phase.loading {
        didSet { setNeedsUpdateProperties() }
    }
    private var shownPhase: Phase?
    /// The page on screen: the plain reader, or the review reader of an editable
    /// Skill's file.
    private var embeddedContent: UIViewController?
    private var loadTask: Task<Void, Never>?
    /// The editable reading of this file, when the server's catalog proves this
    /// Skill is editable and this is one of its own files. It is the same review
    /// reader a Skill's file opens from Server Skills, so the pencil, the "…"
    /// and the editor are that entry's, not a second copy of them.
    private var editableFile: (hostPath: String, skillFile: SkillFileEditTarget, summary: ServerSkillSummary)?

    init(
        skillName: String,
        filePath: String,
        cwd: String?,
        connection: ServerConnection,
        root: AppRootEnvironment,
        reviewCommentSelectionScope: ReviewCommentSelectionScope?
    ) {
        self.skillName = skillName
        self.filePath = filePath
        self.cwd = cwd
        self.connection = connection
        self.root = root
        self.reviewCommentSelectionScope = reviewCommentSelectionScope
        super.init(nibName: nil, bundle: nil)
        traitOverrides.appRootEnvironment = root
        navigationItem.largeTitleDisplayMode = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        loadTask?.cancel()
    }

    private var fileName: String {
        filePath.components(separatedBy: "/").last ?? filePath
    }

    /// Whether the catalog proves this is an editable Skill's own file. The
    /// catalog's `path` is the host path the reader's Skill resolved to, so a
    /// project Skill that shares a global one's name is not confused for it;
    /// a Skill either side cannot name by path stays read-only.
    private static func editableFile(
        detail: SkillDetail,
        filePath: String,
        skills: [ServerSkillSummary]
    ) -> (hostPath: String, skillFile: SkillFileEditTarget, summary: ServerSkillSummary)? {
        let skillPath = (detail.skill.path as NSString).standardizingPath
        // The path only identifies the Skill; `editable` is the summary's to say.
        // A path either side cannot name picks no Skill at all, so a project
        // Skill that shadows a global one is never edited as that Skill.
        guard !skillPath.isEmpty, skillPath != ".",
              let summary = skills.first(where: {
                  guard let candidate = $0.path, !candidate.isEmpty else { return false }
                  return (candidate as NSString).standardizingPath == skillPath
              }),
            case .editable(let hostPath) = ServerSkillFilePresentation.resolve(
                editable: summary.editable,
                resourcePath: summary.path,
                selectedFilePath: filePath
            )
        else { return nil }
        return (hostPath, SkillFileEditTarget(skillId: summary.id, path: filePath), summary)
    }

    private var isShowingFile: Bool {
        if case .loaded = phase { return true }
        return false
    }

    /// The reader draws its own bar, so the stack's hides while it shows.
    var hidesNavigationBar: Bool { isShowingFile }

    // MARK: - Lifecycle

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(true, animated: animated)
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        // The fetch runs on every appearance, as the hosted screen's task did.
        load()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        loadTask?.cancel()
        loadTask = nil
    }

    override func updateProperties() {
        super.updateProperties()
        view.backgroundColor = root.themeStore.backgroundColor
        let themeID = ThemeRuntimeState.currentThemeID()
        if shownPhase != phase {
            shownPhase = phase
            show(phase)
        }
        (embeddedContent as? FullScreenCodeViewController)?.applyThemeIfNeeded(themeID)
        navigationItem.title = isShowingFile ? "" : fileName
        navigationController?.updateNavigationBar(for: self, animated: false)
    }

    // MARK: - Content

    private func show(_ phase: Phase) {
        removeReader()
        switch phase {
        case .loading:
            contentUnavailableConfiguration = UIContentUnavailableConfiguration.loadState(
                .loading(String(localized: "Loading…")),
                palette: ThemeRuntimeState.currentPalette(),
                background: root.themeStore.backgroundColor
            )
        case .failed(let message):
            contentUnavailableConfiguration = UIContentUnavailableConfiguration.loadState(
                .failed(
                    title: String(localized: "Failed to load"),
                    message: message,
                    retry: RetryAction { [weak self] in
                        self?.phase = .loading
                        self?.load()
                    }
                ),
                palette: ThemeRuntimeState.currentPalette(),
                background: root.themeStore.backgroundColor
            )
        case .loaded(let text):
            contentUnavailableConfiguration = nil
            embedLoaded(text: text)
        }
    }

    /// An editable Skill's file shows the review reader Server Skills uses, so
    /// its pencil and "…" come from the one owner; anything else shows the
    /// plain reader it always had.
    private func embedLoaded(text: String) {
        if let editable = editableFile {
            embed(ReviewableControlMarkdownViewController(
                hostFilePath: editable.hostPath,
                serverId: connection.currentServerId ?? "",
                title: filePath,
                skillFile: editable.skillFile,
                domain: .skills,
                targetId: editable.summary.id,
                targetName: editable.summary.name,
                sourceLabel: "\(editable.summary.name) / \(filePath)",
                connection: connection
            ))
            return
        }
        let reader = FullScreenCodeViewController(
            content: .fromText(text, filePath: filePath),
            presentationMode: .embedded(onDismiss: { [weak self] in
                guard let self else { return }
                Router.finish(self)
            }),
            reviewCommentSelectionContext: reviewCommentSelectionScope?.makeContext(
                sessionId: nil,
                sourceLabel: nil
            )
        )
        embed(reader)
    }

    /// The page takes the whole screen under the reader's own glass bar.
    private func embed(_ content: UIViewController) {
        addChild(content)
        content.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content.view)
        NSLayoutConstraint.activate([
            content.view.topAnchor.constraint(equalTo: view.topAnchor),
            content.view.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            content.view.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            content.view.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
        ])
        content.didMove(toParent: self)
        embeddedContent = content
    }

    private func removeReader() {
        guard let reader = embeddedContent else { return }
        reader.willMove(toParent: nil)
        reader.view.removeFromSuperview()
        reader.removeFromParent()
        embeddedContent = nil
    }

    // MARK: - Loading

    /// The file, and the catalog entry that proves its Skill is editable. The
    /// detail carries the Skill's own path (`cwd` may have made it a project
    /// Skill), so the catalog is matched by path and never by name.
    private func load() {
        loadTask?.cancel()
        guard let api = connection.apiClient, let serverId = connection.currentServerId else {
            if !isShowingFile { phase = .failed(String(localized: "Not connected")) }
            return
        }
        let skillName = skillName
        let filePath = filePath
        let cwd = cwd
        let store = connection.serverResourceStore
        loadTask = Task { [weak self] in
            do {
                let detail = try await api.getSkillDetail(name: skillName, cwd: cwd)
                let text = try await api.getSkillFile(name: skillName, path: filePath, cwd: cwd)
                // The catalog is filled by the Skills, Agents and Extensions
                // screens; a chat can reach a Skill before any of them ran.
                if !store.hasLoadedSkills(forServer: serverId) {
                    await store.load(serverId: serverId, api: api)
                }
                guard !Task.isCancelled else { return }
                let editableFile = Self.editableFile(
                    detail: detail,
                    filePath: filePath,
                    skills: store.skills(forServer: serverId)
                )
                logger.debug("Loaded skill file: \(skillName)/\(filePath)")
                guard let self else { return }
                self.editableFile = editableFile
                self.phase = .loaded(text)
            } catch {
                guard !Task.isCancelled else { return }
                logger.error("Failed to load \(skillName)/\(filePath): \(error.localizedDescription)")
                // A refetch that fails keeps the file already on screen.
                guard let self, !isShowingFile else { return }
                phase = .failed(error.localizedDescription)
            }
        }
    }
}
