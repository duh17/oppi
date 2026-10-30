import UIKit
import os.log

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "SkillDetail")

/// A skill's SKILL.md content, its file count, and its file list, on one
/// server. Opened from Workspace Skills (a project folder's skills) and from
/// the chat's Context panel. A file opens `SkillFileViewController`.
///
/// Stale-while-revalidate: a global skill (no `cwd`) shows its cached detail
/// at once and refreshes from the server in the background. A project-local
/// detail is scoped by `cwd` and always fetched, so it never shows a stale
/// match from another folder.
@MainActor
final class SkillDetailViewController: UIViewController {
    private enum Phase: Equatable {
        case loading
        case failed(String)
        case loaded
    }

    private static let pageMargin: CGFloat = 16

    private let skillName: String
    private let cwd: String?
    private let connection: ServerConnection
    private let root: AppRootEnvironment
    private let reviewCommentSelectionScope: ReviewCommentSelectionScope?

    private var detail: SkillDetail? {
        didSet { setNeedsUpdateProperties() }
    }
    private var error: String? {
        didSet { setNeedsUpdateProperties() }
    }
    private var isLoading = true {
        didSet { setNeedsUpdateProperties() }
    }
    private var loadTask: Task<Void, Never>?
    private var renderedDetailFiles: [String]?
    private var appliedThemeID: ThemeID?

    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private let descriptionLabel = UILabel()
    private let filesPill = InsetLabel(insets: UIEdgeInsets(top: 4, left: 8, bottom: 4, right: 8), capsule: true)
    private let pillRow = UIView()
    private let markdownDivider = SkillDetailDivider()
    private let markdownView = AssistantMarkdownContentView()
    private let filesDivider = SkillDetailDivider()
    private let filesHeader = UILabel()
    private let filesStack = UIStackView()

    init(
        skillName: String,
        cwd: String? = nil,
        connection: ServerConnection,
        root: AppRootEnvironment,
        reviewCommentSelectionScope: ReviewCommentSelectionScope?
    ) {
        self.skillName = skillName
        self.cwd = cwd
        self.connection = connection
        self.root = root
        self.reviewCommentSelectionScope = reviewCommentSelectionScope
        super.init(nibName: nil, bundle: nil)
        traitOverrides.appRootEnvironment = root
        title = skillName
        navigationItem.largeTitleDisplayMode = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        loadTask?.cancel()
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        buildLayout()
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeDidChange), name: .oppiThemeDidChange, object: nil
        )
        // A live text-size change draws the file rows again.
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: Self, _) in
            self.renderedDetailFiles = nil
            self.setNeedsUpdateProperties()
        }
        setNeedsUpdateProperties()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(true, animated: animated)
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        // The load runs on every appearance, as the hosted screen's task did.
        load()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        loadTask?.cancel()
        loadTask = nil
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Diagrams lay out at the width the Markdown is shown at.
        let width = scrollView.bounds.width - 2 * Self.pageMargin
        if width > 0 { markdownView.hostLayoutWidth = width }
    }

    @objc private func themeDidChange() { setNeedsUpdateProperties() }

    override func updateProperties() {
        super.updateProperties()
        // Read the theme so a change re-runs this pass.
        _ = (root.themeStore.mode, root.themeStore.manualThemeID)
        let themeID = ThemeRuntimeState.currentThemeID()
        let themeChanged = appliedThemeID != themeID
        appliedThemeID = themeID
        overrideUserInterfaceStyle = root.themeStore.userInterfaceStyle
        view.backgroundColor = root.themeStore.backgroundColor

        switch phase {
        case .loading:
            scrollView.isHidden = true
            contentUnavailableConfiguration = UIContentUnavailableConfiguration.loadState(
                .loading(String(localized: "Loading skill…")),
                palette: ThemeRuntimeState.currentPalette(),
                background: root.themeStore.backgroundColor
            )
        case .failed(let message):
            scrollView.isHidden = true
            contentUnavailableConfiguration = UIContentUnavailableConfiguration.loadState(
                .failed(
                    title: String(localized: "Failed to load"),
                    message: message,
                    retry: RetryAction { [weak self] in self?.load() }
                ),
                palette: ThemeRuntimeState.currentPalette(),
                background: root.themeStore.backgroundColor
            )
        case .loaded:
            contentUnavailableConfiguration = nil
            scrollView.isHidden = false
            if let detail { apply(detail, themeChanged: themeChanged) }
        }
    }

    private var phase: Phase {
        if detail != nil { return .loaded }
        if isLoading { return .loading }
        if let error { return .failed(error) }
        return .loading
    }

    // MARK: - Layout

    private func buildLayout() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        scrollView.accessibilityIdentifier = "skill.detail.scroll"
        view.addSubview(scrollView)

        stack.axis = .vertical
        stack.spacing = 16
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(
            top: Self.pageMargin, left: Self.pageMargin, bottom: Self.pageMargin, right: Self.pageMargin
        )
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)

        descriptionLabel.font = .preferredFont(forTextStyle: .subheadline)
        descriptionLabel.adjustsFontForContentSizeCategory = true
        descriptionLabel.numberOfLines = 0
        descriptionLabel.accessibilityIdentifier = "skill.detail.description"

        filesPill.font = .scaled(.caption1, .semibold)
        filesPill.accessibilityIdentifier = "skill.detail.fileCount"
        filesPill.translatesAutoresizingMaskIntoConstraints = false
        pillRow.addSubview(filesPill)

        markdownView.backgroundColor = .clear
        markdownView.accessibilityIdentifier = "skill.detail.content"

        filesHeader.font = .preferredFont(forTextStyle: .headline)
        filesHeader.adjustsFontForContentSizeCategory = true
        filesHeader.text = String(localized: "Files")
        filesHeader.accessibilityTraits = .header
        filesStack.axis = .vertical
        filesStack.spacing = 0

        // The header, its rows, and the divider above them are one section.
        let filesSection = UIStackView(arrangedSubviews: [filesHeader, filesStack])
        filesSection.axis = .vertical
        filesSection.spacing = 8

        for item in [descriptionLabel, pillRow, markdownDivider, markdownView, filesDivider, filesSection] {
            stack.addArrangedSubview(item)
        }
        stack.setCustomSpacing(8, after: descriptionLabel)
        // The sections the content hides are the files divider and section.
        filesSection.accessibilityIdentifier = "skill.detail.files"

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            filesPill.topAnchor.constraint(equalTo: pillRow.topAnchor),
            filesPill.bottomAnchor.constraint(equalTo: pillRow.bottomAnchor),
            filesPill.leadingAnchor.constraint(equalTo: pillRow.leadingAnchor),
            filesPill.trailingAnchor.constraint(lessThanOrEqualTo: pillRow.trailingAnchor),
        ])
    }

    private func apply(_ detail: SkillDetail, themeChanged: Bool) {
        let palette = ThemeRuntimeState.currentPalette()
        let themeID = ThemeRuntimeState.currentThemeID()
        let comment = UIColor(palette.comment)
        let hasFiles = detail.files.count > 1

        descriptionLabel.text = detail.skill.description
        descriptionLabel.textColor = comment

        pillRow.isHidden = !hasFiles
        if hasFiles {
            let text = String(localized: "\(detail.files.count) files")
            let icon = NSTextAttachment()
            icon.image = UIImage.scaledSymbol("doc.on.doc", style: .caption1, weight: .semibold, color: comment)
            let label = NSMutableAttributedString(attachment: icon)
            label.append(NSAttributedString(string: " \(text)"))
            label.addAttributes(
                [.font: UIFont.scaled(.caption1, .semibold), .foregroundColor: comment],
                range: NSRange(location: 0, length: label.length)
            )
            filesPill.attributedText = label
            filesPill.backgroundColor = UIColor(palette.fg).withAlphaComponent(0.08)
            filesPill.accessibilityLabel = text
        }

        let hasContent = !detail.content.isEmpty
        markdownDivider.isHidden = !hasContent
        markdownView.isHidden = !hasContent
        if hasContent {
            // The content view skips identical configurations itself.
            markdownView.apply(configuration: .make(
                content: detail.content,
                isStreaming: false,
                themeID: themeID,
                reviewCommentSelectionRouter: reviewCommentSelectionScope?.router
            ))
        }

        filesDivider.isHidden = !hasFiles
        filesStack.superview?.isHidden = !hasFiles
        if hasFiles, themeChanged || renderedDetailFiles != detail.files {
            renderedDetailFiles = detail.files
            filesStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
            for file in detail.files {
                filesStack.addArrangedSubview(fileRow(file, palette: palette))
            }
        }
        filesHeader.textColor = UIColor(palette.fg)
    }

    private func fileRow(_ file: String, palette: ThemePalette) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0)
        configuration.image = Self.centered(UIImage.scaledSymbol(
            Self.fileIcon(for: file), style: .caption1, color: UIColor(palette.comment)
        ))
        configuration.imagePadding = 6
        configuration.titleAlignment = .leading
        var title = AttributedString(file)
        title.font = UIFont.scaledMonospaced(.caption1)
        title.foregroundColor = UIColor(palette.fg)
        configuration.attributedTitle = title
        let button = UIButton(configuration: configuration)
        button.contentHorizontalAlignment = .leading
        button.accessibilityIdentifier = "skill.detail.file.\(file)"
        // A file's row is a full-size touch target.
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        button.addAction(UIAction { [weak self] _ in self?.openFile(file) }, for: .touchUpInside)
        return button
    }

    /// The symbol centered in a column at least 16 points wide, so file names
    /// line up unless a symbol is wider than the column.
    private static func centered(_ image: UIImage?) -> UIImage? {
        guard let image else { return nil }
        let size = CGSize(width: max(16, image.size.width), height: image.size.height)
        return UIGraphicsImageRenderer(size: size).image { _ in
            image.draw(at: CGPoint(x: (size.width - image.size.width) / 2, y: 0))
        }
    }

    /// Pushes the file's reader on this screen's server and folder.
    private func openFile(_ file: String) {
        let reader = SkillFileViewController(
            skillName: skillName,
            filePath: file,
            cwd: cwd,
            connection: connection,
            root: root,
            reviewCommentSelectionScope: reviewCommentSelectionScope
        )
        Router.push(reader, from: self)
    }

    // MARK: - Loading

    private func load() {
        loadTask?.cancel()
        error = nil
        if detail == nil { isLoading = true }
        let skillName = skillName
        let cwd = cwd
        let connection = connection
        loadTask = Task { [weak self] in
            // Stale-while-revalidate for global skill details. Project-local
            // details are scoped by cwd and fetched directly to avoid stale matches.
            if cwd == nil {
                let cached: SkillDetail?
                if let cacheServerId = connection.currentServerId {
                    cached = await TimelineCache.shared.loadSkillDetail(skillName, serverId: cacheServerId)
                } else {
                    cached = await TimelineCache.shared.loadSkillDetail(skillName)
                }
                guard !Task.isCancelled, let self else { return }
                if let cached {
                    detail = cached
                    isLoading = false
                }
            }

            guard let api = connection.apiClient else {
                guard let self, detail == nil else { return }
                error = String(localized: "Not connected")
                isLoading = false
                return
            }

            do {
                let fresh = try await api.getSkillDetail(name: skillName, cwd: cwd)
                guard !Task.isCancelled, let self else { return }
                detail = fresh
                if cwd == nil {
                    if let cacheServerId = connection.currentServerId {
                        await TimelineCache.shared.saveSkillDetail(skillName, detail: fresh, serverId: cacheServerId)
                    } else {
                        await TimelineCache.shared.saveSkillDetail(skillName, detail: fresh)
                    }
                }
                logger.debug("Loaded skill detail: \(skillName) (\(fresh.files.count) files)")
            } catch {
                guard !Task.isCancelled, let self else { return }
                logger.error("Failed to load skill \(skillName): \(error.localizedDescription)")
                if detail == nil {
                    self.error = error.localizedDescription
                }
            }
            self?.isLoading = false
        }
    }

    // MARK: - Helpers

    private static func fileIcon(for path: String) -> String {
        if path.hasSuffix(".md") { return "doc.text" }
        if path.hasSuffix(".py") { return "chevron.left.forwardslash.chevron.right" }
        if path.hasSuffix(".sh") || !path.contains(".") { return "terminal" }
        if path.hasSuffix(".ts") || path.hasSuffix(".js") { return "chevron.left.forwardslash.chevron.right" }
        if path.hasSuffix(".json") || path.hasSuffix(".yml") || path.hasSuffix(".yaml") { return "curlybraces" }
        return "doc"
    }
}

/// A one-pixel rule across the page, in the system separator color.
private final class SkillDetailDivider: UIView {
    private var height: NSLayoutConstraint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .separator
        isAccessibilityElement = false
        let height = heightAnchor.constraint(equalToConstant: 1)
        height.isActive = true
        self.height = height
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        height?.constant = 1 / max(traitCollection.displayScale, 1)
    }
}
