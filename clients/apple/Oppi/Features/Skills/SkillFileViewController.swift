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
    private var reader: FullScreenCodeViewController?
    private var loadTask: Task<Void, Never>?
    /// The document's edit entry: its pencil edits this file through its Skill
    /// when the server's catalog says the Skill is editable.
    private lazy var editOwner = makeEditOwner()

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

    /// The Skill this file belongs to, as the server's catalog names it: the one
    /// Skill with this reader's name, when it is editable and this is one of its
    /// own files. Nil shows no pencil, and the reader keeps the bar it had.
    private var skillFile: SkillFileEditTarget? {
        guard let serverId = connection.currentServerId else { return nil }
        return ServerSkillFilePresentation.editTarget(
            skillName: skillName,
            filePath: filePath,
            skills: connection.serverResourceStore.skills(forServer: serverId)
        )
    }

    private func makeEditOwner() -> DocumentEditOwner? {
        guard let skillFile else { return nil }
        let subject = DocumentEditSubject.file(
            serverId: connection.currentServerId,
            source: .hostFile,
            workspaceId: "",
            worktreeId: nil,
            path: filePath,
            skillFile: skillFile,
            fileType: FileType.detect(from: filePath)
        )
        return DocumentEditOwner(
            subject: subject,
            backend: { [weak self] in
                guard let self, let api = connection.apiClient else { return nil }
                return .make(for: subject, api: api)
            },
            handlers: .init(
                makePreview: { [weak self] text in
                    FullScreenCodeViewController(
                        content: .fromText(text, filePath: self?.filePath),
                        presentationMode: .contentOnly()
                    )
                }
            ),
            onChange: { [weak self] in self?.setNeedsUpdateProperties() }
        )
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
        reader?.applyThemeIfNeeded(themeID)
        reader?.setEditBarItems(editOwner?.barItems ?? [])
        editOwner?.updateEditorPage(palette: root.themeStore.activeThemeID.palette, checkoutSubtitle: nil)
        editOwner?.presentEditorIfNeeded(from: self)
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
            embedReader(text: text)
        }
    }

    private func embedReader(text: String) {
        let reader = FullScreenCodeViewController(
            content: .fromText(text, filePath: filePath),
            presentationMode: .embedded(onDismiss: { [weak self] in
                guard let self else { return }
                Router.finish(self)
            }),
            reviewCommentSelectionContext: reviewCommentSelectionScope?.makeContext(
                sessionId: nil,
                sourceLabel: nil
            ),
            editItems: editOwner?.barItems ?? []
        )
        if let editOwner {
            Task { [weak self] in
                _ = await editOwner.read()
                self?.setNeedsUpdateProperties()
            }
        }
        addChild(reader)
        reader.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(reader.view)
        // The reader's own glass bar sits at the top of the screen.
        NSLayoutConstraint.activate([
            reader.view.topAnchor.constraint(equalTo: view.topAnchor),
            reader.view.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            reader.view.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            reader.view.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
        ])
        reader.didMove(toParent: self)
        self.reader = reader
    }

    private func removeReader() {
        // The editor holds the live buffer: hand it back before the reader goes.
        editOwner?.finishEditing()
        guard let reader else { return }
        reader.willMove(toParent: nil)
        reader.view.removeFromSuperview()
        reader.removeFromParent()
        self.reader = nil
    }

    // MARK: - Loading

    private func load() {
        loadTask?.cancel()
        guard let api = connection.apiClient else {
            if !isShowingFile { phase = .failed(String(localized: "Not connected")) }
            return
        }
        let skillName = skillName
        let filePath = filePath
        let cwd = cwd
        loadTask = Task { [weak self] in
            do {
                let text = try await api.getSkillFile(name: skillName, path: filePath, cwd: cwd)
                guard !Task.isCancelled else { return }
                logger.debug("Loaded skill file: \(skillName)/\(filePath)")
                self?.phase = .loaded(text)
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
