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
final class SkillFileViewController: UIViewController {
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

    private var isShowingFile: Bool {
        if case .loaded = phase { return true }
        return false
    }

    // MARK: - Lifecycle

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(true, animated: animated)
        applyHostNavigationBar(animated: animated)
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
        navigationItem.title = isShowingFile ? "" : fileName
        applyHostNavigationBar(animated: false)
    }

    /// The reader draws its own bar, so the stack's hides while it shows.
    private func applyHostNavigationBar(animated: Bool) {
        guard let navigation = navigationController,
              navigation.topViewController === self,
              navigation.isNavigationBarHidden != isShowingFile else { return }
        navigation.setNavigationBarHidden(isShowingFile, animated: animated)
    }

    // MARK: - Content

    private func show(_ phase: Phase) {
        removeReader()
        switch phase {
        case .loading:
            var loading = UIContentUnavailableConfiguration.loading()
            loading.text = String(localized: "Loading…")
            loading.background.backgroundColor = root.themeStore.backgroundColor
            contentUnavailableConfiguration = loading
        case .failed(let message):
            var failed = UIContentUnavailableConfiguration.empty()
            failed.image = UIImage(systemName: "exclamationmark.triangle")
            failed.text = String(localized: "Failed to load")
            failed.secondaryText = message
            failed.background.backgroundColor = root.themeStore.backgroundColor
            contentUnavailableConfiguration = failed
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
            )
        )
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
