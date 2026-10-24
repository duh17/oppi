import UIKit

enum ReviewCommentStashChrome {
    case sheet
    case drawer
}

// MARK: - List

/// The staged comments, oldest first, one row each: location, Edit and
/// Remove, the selected text, and the body (which also edits). Rows sit
/// flush in the drawer and 16pt in from the sheet's edges.
final class ReviewCommentStashListView: UIView {
    var onRequestEdit: ((ReviewComment) -> Void)?
    var onDelete: ((ReviewComment) -> Void)?

    private let chrome: ReviewCommentStashChrome
    private let stack = UIStackView()
    private var shown: [ReviewComment] = []
    private var shownTheme: ThemeID?

    init(chrome: ReviewCommentStashChrome) {
        self.chrome = chrome
        super.init(frame: .zero)
        stack.axis = .vertical
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(comments: [ReviewComment], themeID: ThemeID) {
        let sorted = comments.sorted { $0.createdAt < $1.createdAt }
        guard sorted != shown || shownTheme != themeID else { return }
        shown = sorted
        shownTheme = themeID
        let palette = themeID.palette
        for view in stack.arrangedSubviews { view.removeFromSuperview() }
        let inset: CGFloat = chrome == .drawer ? 0 : 16
        for (index, comment) in sorted.enumerated() {
            let row = ReviewCommentStashRowView(comment: comment, among: comments, palette: palette)
            row.onEdit = { [weak self] in self?.onRequestEdit?(comment) }
            row.onDelete = { [weak self] in self?.onDelete?(comment) }
            stack.addArrangedSubview(Self.padded(row, horizontal: inset, vertical: 4))
            if index < sorted.count - 1 {
                let divider = UIView()
                divider.backgroundColor = UIColor.separator
                divider.heightAnchor.constraint(equalToConstant: 1 / max(1, traitCollection.displayScale)).isActive = true
                stack.addArrangedSubview(Self.padded(divider, horizontal: 0, leading: inset))
            }
        }
    }

    private static func padded(
        _ view: UIView,
        horizontal: CGFloat,
        leading: CGFloat? = nil,
        vertical: CGFloat = 0
    ) -> UIView {
        let box = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: box.topAnchor, constant: vertical),
            view.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -vertical),
            view.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: leading ?? horizontal),
            view.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -horizontal),
        ])
        return box
    }
}

private final class ReviewCommentStashRowView: UIView {
    var onEdit: (() -> Void)?
    var onDelete: (() -> Void)?

    init(comment: ReviewComment, among comments: [ReviewComment], palette: ThemePalette) {
        super.init(frame: .zero)
        let icon = UIImageView(image: UIImage.scaledSymbol("text.bubble.fill", style: .caption1, weight: .semibold, color: UIColor(palette.cyan)))
        icon.setContentHuggingPriority(.required, for: .horizontal)
        let location = UILabel()
        location.font = UIFont.scaledMonospaced(.caption1, .regular)
        location.adjustsFontForContentSizeCategory = true
        location.textColor = UIColor(palette.comment)
        location.numberOfLines = 2
        location.lineBreakMode = .byTruncatingMiddle
        location.text = ReviewCommentStashLocation.compactText(for: comment, among: comments)
        location.accessibilityLabel = ReviewCommentStashLocation.completeText(for: comment)
        location.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let edit = Self.iconButton("pencil", color: UIColor(palette.blue), label: "Edit review comment")
        edit.addAction(UIAction { [weak self] _ in self?.onEdit?() }, for: .touchUpInside)
        let delete = Self.iconButton("trash", color: UIColor(palette.red), label: "Remove review comment")
        delete.addAction(UIAction { [weak self] _ in self?.onDelete?() }, for: .touchUpInside)
        let header = UIStackView(arrangedSubviews: [icon, location, edit, delete])
        header.axis = .horizontal
        header.alignment = .center
        header.spacing = 8

        let stack = UIStackView(arrangedSubviews: [header])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 10
        if let selectedText = comment.stashSelectedText {
            let selected = UILabel()
            selected.font = UIFont.scaledMonospaced(.caption1, .regular)
            selected.adjustsFontForContentSizeCategory = true
            selected.textColor = UIColor(palette.fgDim)
            selected.numberOfLines = 3
            selected.text = selectedText
            let well = UIView()
            well.backgroundColor = UIColor(palette.bgHighlight).withAlphaComponent(0.55)
            well.layer.cornerRadius = 10
            well.layer.cornerCurve = .continuous
            selected.translatesAutoresizingMaskIntoConstraints = false
            well.addSubview(selected)
            NSLayoutConstraint.activate([
                selected.topAnchor.constraint(equalTo: well.topAnchor, constant: 8),
                selected.bottomAnchor.constraint(equalTo: well.bottomAnchor, constant: -8),
                selected.leadingAnchor.constraint(equalTo: well.leadingAnchor, constant: 10),
                selected.trailingAnchor.constraint(equalTo: well.trailingAnchor, constant: -10),
            ])
            stack.addArrangedSubview(well)
        }
        let body = UIButton(type: .custom)
        var configuration = UIButton.Configuration.plain()
        var title = AttributedString(comment.body)
        title.font = UIFont.preferredFont(forTextStyle: .body)
        title.foregroundColor = UIColor(palette.fg)
        configuration.attributedTitle = title
        configuration.contentInsets = .zero
        configuration.titleAlignment = .leading
        configuration.titleLineBreakMode = .byWordWrapping
        body.configuration = configuration
        body.contentHorizontalAlignment = .leading
        body.accessibilityLabel = "Edit review comment"
        body.addAction(UIAction { [weak self] _ in self?.onEdit?() }, for: .touchUpInside)
        stack.addArrangedSubview(body)

        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private static func iconButton(_ symbol: String, color: UIColor, label: String) -> UIButton {
        let button = UIButton(type: .custom)
        button.setImage(UIImage.scaledSymbol(symbol, style: .caption1, weight: .semibold, color: color), for: .normal)
        button.accessibilityLabel = label
        button.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 44),
            button.heightAnchor.constraint(equalToConstant: 44),
        ])
        return button
    }
}

// MARK: - Sheet

/// The staged review comments in a sheet, at the root of a router navigation
/// controller (`.inNavigation()`): the list, or one comment's editor in its
/// place. It reads the stash live, so edits and removals show while it is up.
final class ReviewCommentStashViewController: UIViewController, UITextViewDelegate {
    private let stash: any ReviewCommentStashHandling
    private let onClose: () -> Void
    private var editingComment: ReviewComment?

    private let scrollView = UIScrollView()
    private let list = ReviewCommentStashListView(chrome: .sheet)
    private let empty = UIContentUnavailableView(configuration: .empty())
    private let editor = ReviewCommentStashViewController.makeEditorList()
    private let commentText = UITextView()
    private let errorLabel = UILabel()
    private lazy var saveItem: UIBarButtonItem = {
        let item = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.save() })
        item.style = .prominent
        item.accessibilityLabel = "Save"
        return item
    }()
    private lazy var editorRowRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, IndexPath> { [weak self] cell, indexPath, _ in
        self?.configureEditorRow(cell, at: indexPath)
    }
    private lazy var editorHeaderRegistration = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
        elementKind: UICollectionView.elementKindSectionHeader
    ) { [weak self] header, _, indexPath in self?.configureEditorHeader(header, at: indexPath) }
    private lazy var cancelItem: UIBarButtonItem = {
        let item = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in
            self?.endEditing()
        })
        item.accessibilityLabel = "Cancel"
        return item
    }()
    private lazy var closeItem: UIBarButtonItem = {
        let item = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in
            self?.onClose()
        })
        item.accessibilityLabel = "Close"
        return item
    }()

    /// `editing` opens straight on that comment's editor.
    init(
        stash: any ReviewCommentStashHandling,
        editing: ReviewComment? = nil,
        onClose: @escaping () -> Void
    ) {
        self.stash = stash
        editingComment = editing
        self.onClose = onClose
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        list.onRequestEdit = { [weak self] in self?.beginEditing($0) }
        list.onDelete = { [weak self] in self?.stash.delete($0) }
        list.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = false
        scrollView.addSubview(list)
        var emptyConfiguration = UIContentUnavailableConfiguration.empty()
        emptyConfiguration.image = UIImage(systemName: "text.bubble")
        emptyConfiguration.text = "No Staged Review Comments"
        emptyConfiguration.secondaryText = "Comments you add from selected text will appear here before you send them."
        empty.configuration = emptyConfiguration

        // Registrations exist before the list asks for a cell.
        _ = (editorRowRegistration, editorHeaderRegistration)
        editor.dataSource = self
        editor.keyboardDismissMode = .interactive
        commentText.font = .preferredFont(forTextStyle: .body)
        commentText.adjustsFontForContentSizeCategory = true
        commentText.backgroundColor = .clear
        commentText.accessibilityLabel = "Review comment text"
        commentText.delegate = self
        errorLabel.font = .preferredFont(forTextStyle: .caption1)
        errorLabel.adjustsFontForContentSizeCategory = true
        errorLabel.numberOfLines = 0
        commentText.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true

        // The editor ends at the keyboard, so the comment field scrolls clear of it.
        view.keyboardLayoutGuide.usesBottomSafeArea = false
        for page in [scrollView, empty, editor] as [UIView] {
            page.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(page)
            NSLayoutConstraint.activate([
                page.topAnchor.constraint(equalTo: view.topAnchor),
                page.bottomAnchor.constraint(
                    equalTo: page === editor ? view.keyboardLayoutGuide.topAnchor : view.bottomAnchor
                ),
                page.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                page.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            ])
        }
        NSLayoutConstraint.activate([
            list.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            list.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -12),
            list.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            list.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
        ])
        if let editingComment { showEditor(for: editingComment) }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if editingComment != nil { commentText.becomeFirstResponder() }
    }

    private var themeID: ThemeID {
        HostFactory.root(near: self)?.themeStore.activeThemeID ?? ThemeRuntimeState.currentThemeID()
    }

    private var palette: ThemePalette { themeID.palette }

    /// Observation re-runs this when the staged comments or the theme change.
    override func updateProperties() {
        super.updateProperties()
        let themeID = themeID
        let palette = themeID.palette
        let comments = stash.stagedComments
        let background = UIColor(palette.bg)
        view.backgroundColor = background
        scrollView.backgroundColor = background
        empty.backgroundColor = background
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = background
        appearance.shadowColor = .clear
        navigationItem.standardAppearance = appearance
        navigationItem.scrollEdgeAppearance = appearance
        navigationItem.compactAppearance = appearance
        list.apply(comments: comments, themeID: themeID)
        errorLabel.textColor = UIColor(palette.red)
        // The theme's accent, as the app root's SwiftUI tint gave the sheet.
        view.tintColor = UIColor(palette.blue)
        for item in [cancelItem, closeItem] { item.tintColor = UIColor(palette.blue) }

        let isEditing = editingComment != nil
        title = isEditing ? "Edit Comment" : ReviewCommentStripChrome.stashTitle(count: comments.count)
        editor.isHidden = !isEditing
        scrollView.isHidden = isEditing || comments.isEmpty
        empty.isHidden = isEditing || !comments.isEmpty
        navigationItem.leftBarButtonItem = isEditing ? cancelItem : closeItem
        navigationItem.rightBarButtonItem = isEditing ? saveItem : nil
        if isEditing { updateSaveEnabled() }
    }

    // MARK: Editing

    private func beginEditing(_ comment: ReviewComment) {
        showEditor(for: comment)
        commentText.becomeFirstResponder()
    }

    private func showEditor(for comment: ReviewComment) {
        editingComment = comment
        commentText.text = comment.body
        errorLabel.text = nil
        editor.reloadData()
        setNeedsUpdateProperties()
    }

    private func endEditing() {
        view.endEditing(true)
        editingComment = nil
        editor.reloadData()
        setNeedsUpdateProperties()
    }

    private var trimmedBody: String {
        (commentText.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func updateSaveEnabled() {
        saveItem.isEnabled = !trimmedBody.isEmpty && trimmedBody != editingComment?.body
    }

    func textViewDidChange(_ textView: UITextView) {
        updateSaveEnabled()
    }

    private func save() {
        guard let comment = editingComment else { return }
        guard !trimmedBody.isEmpty else {
            showError("Review comment body is required.")
            return
        }
        guard trimmedBody != comment.body else {
            endEditing()
            return
        }
        if stash.update(comment, body: trimmedBody) == nil {
            endEditing()
        } else {
            showError("Could not save the review comment.")
        }
    }

    /// Adds or refreshes only the error row: reloading the list would take
    /// the keyboard from the comment field.
    private func showError(_ message: String) {
        let hadError = errorLabel.text != nil
        errorLabel.text = message
        guard let section = editorSections.firstIndex(of: .comment) else { return }
        let row = IndexPath(item: 1, section: section)
        if hadError {
            editor.reconfigureItems(at: [row])
        } else {
            editor.insertItems(at: [row])
        }
    }
}

// MARK: Editor list

extension ReviewCommentStashViewController: UICollectionViewDataSource {
    fileprivate enum EditorSection {
        case location, selectedText, comment
    }

    private var editorSections: [EditorSection] {
        guard let editingComment else { return [] }
        return editingComment.stashSelectedText == nil ? [.location, .comment] : [.location, .selectedText, .comment]
    }

    static func makeEditorList() -> UICollectionView {
        var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        configuration.headerMode = .supplementary
        let list = UICollectionView(
            frame: .zero,
            collectionViewLayout: UICollectionViewCompositionalLayout.list(using: configuration)
        )
        list.allowsSelection = false
        return list
    }

    func numberOfSections(in collectionView: UICollectionView) -> Int {
        editorSections.count
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        editorSections[section] == .comment && errorLabel.text != nil ? 2 : 1
    }

    func collectionView(
        _ collectionView: UICollectionView,
        viewForSupplementaryElementOfKind kind: String,
        at indexPath: IndexPath
    ) -> UICollectionReusableView {
        collectionView.dequeueConfiguredReusableSupplementary(using: editorHeaderRegistration, for: indexPath)
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        collectionView.dequeueConfiguredReusableCell(using: editorRowRegistration, for: indexPath, item: indexPath)
    }

    fileprivate func configureEditorHeader(_ header: UICollectionViewListCell, at indexPath: IndexPath) {
        var content = UIListContentConfiguration.header()
        content.text = switch editorSections[indexPath.section] {
        case .location: "Location"
        case .selectedText: "Selected Text"
        case .comment: "Comment"
        }
        header.contentConfiguration = content
    }

    fileprivate func configureEditorRow(_ cell: UICollectionViewListCell, at indexPath: IndexPath) {
        // Rows embed their own views; a reused cell drops the previous row's.
        cell.contentConfiguration = nil
        for view in cell.contentView.subviews { view.removeFromSuperview() }
        let palette = palette
        guard let editing = editingComment else { return }
        switch editorSections[indexPath.section] {
        case .location:
            var content = UIListContentConfiguration.cell()
            content.text = ReviewCommentStashLocation.completeText(for: editing)
            content.textProperties.font = UIFont.scaledMonospaced(.caption1, .regular)
            content.textProperties.color = UIColor(palette.comment)
            cell.contentConfiguration = content
        case .selectedText:
            let text = UITextView()
            text.isEditable = false
            text.isScrollEnabled = false
            text.backgroundColor = .clear
            // The list row's text inset, as a plain text row gets.
            text.textContainerInset = UIEdgeInsets(top: 11, left: 0, bottom: 11, right: 0)
            text.textContainer.lineFragmentPadding = 0
            text.font = UIFont.scaledMonospaced(.caption1, .regular)
            text.adjustsFontForContentSizeCategory = true
            text.textColor = UIColor(palette.fgDim)
            text.text = editing.stashSelectedText
            embed(text, in: cell)
        case .comment where indexPath.item == 0:
            embed(commentText, in: cell)
        case .comment:
            embed(errorLabel, in: cell)
        }
    }

    private func embed(_ content: UIView, in cell: UICollectionViewListCell) {
        content.removeFromSuperview()
        content.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(content)
        let margins = cell.contentView.layoutMarginsGuide
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: margins.topAnchor),
            content.bottomAnchor.constraint(equalTo: margins.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
        ])
    }
}

extension ReviewComment {
    fileprivate var stashSelectedText: String? {
        guard let text = reference.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }
}
