import UIKit

/// Previous/next file buttons in the bottom corners. Horizontal swipes stay
/// reserved for back. Hidden while the editor is open.
@MainActor
final class AdjacentFileNavigatorButtons {
    private var buttons: [AdjacentFileNavigatorLayout.Corner: UIButton] = [:]
    private var themeID: ThemeID?
    private let onSelect: (FileBrowserNavigationDirection) -> Void

    init(onSelect: @escaping (FileBrowserNavigationDirection) -> Void) {
        self.onSelect = onSelect
    }

    /// Shows the buttons `canGoPrevious` and `canGoNext` allow on `host`.
    func update(on host: UIView, canGoPrevious: Bool, canGoNext: Bool, themeID: ThemeID) {
        let slots = AdjacentFileNavigatorLayout.slots(canGoPrevious: canGoPrevious, canGoNext: canGoNext)
        let palette = themeID.palette
        let paletteChanged = self.themeID != themeID
        self.themeID = themeID
        for corner in [AdjacentFileNavigatorLayout.Corner.leading, .trailing] {
            guard let slot = slots.first(where: { $0.corner == corner }) else {
                buttons[corner]?.removeFromSuperview()
                buttons[corner] = nil
                continue
            }
            if let button = buttons[corner] {
                if paletteChanged {
                    FullScreenFloatingControlChrome.updateStandaloneButton(button, palette: palette)
                }
                host.bringSubviewToFront(button)
                continue
            }
            let button = FullScreenFloatingControlChrome.makeStandaloneButton(
                systemImage: slot.systemImage,
                accessibilityLabel: slot.accessibilityLabel,
                palette: palette
            )
            let direction: FileBrowserNavigationDirection = corner == .leading ? .previous : .next
            button.addAction(UIAction { [weak self] _ in self?.onSelect(direction) }, for: .primaryActionTriggered)
            host.addSubview(button)
            FullScreenFloatingControlChrome.pinStandaloneButton(button, to: host, leading: corner == .leading)
            buttons[corner] = button
        }
    }
}

/// The staged-comment button for content without the reader's own (images,
/// media, review diffs): bottom leading, above the previous-file button. It
/// shows while the scope's stash has comments and opens them in a sheet.
@MainActor
final class ReviewCommentStashFloatingButton {
    private var button: UIButton?
    private let badge = UILabel()
    private var bottom: NSLayoutConstraint?
    private var lastCount = 0
    private weak var sheet: UIViewController?

    init() {
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.font = .systemFont(ofSize: 11, weight: .bold)
        badge.textAlignment = .center
        badge.layer.cornerRadius = 9
        badge.layer.masksToBounds = true
        badge.isAccessibilityElement = false
        badge.isUserInteractionEnabled = false
    }

    /// Reads the stash's `@Observable` count: call from `updateProperties()`.
    func update(
        on host: UIView,
        presenter: UIViewController,
        scope: ReviewCommentSelectionScope?,
        leadingAccessoryCount: Int,
        palette: ThemePalette
    ) {
        let comments = scope?.router.stash as? ChatReviewCommentsController
        let count = comments?.stagedCount ?? 0
        guard let comments, count > 0 else {
            badge.removeFromSuperview()
            button?.removeFromSuperview()
            button = nil
            bottom = nil
            lastCount = 0
            return
        }
        let button: UIButton
        if let existing = self.button {
            button = existing
            FullScreenFloatingControlChrome.updateStandaloneButton(button, palette: palette)
        } else {
            button = FullScreenFloatingControlChrome.makeStandaloneButton(
                systemImage: FullScreenReviewCommentStashControl.systemImage,
                accessibilityLabel: FullScreenReviewCommentStashControl.accessibilityLabel,
                accessibilityIdentifier: FullScreenReviewCommentStashControl.accessibilityIdentifier,
                palette: palette
            )
            button.clipsToBounds = false
            button.isAccessibilityElement = true
            button.accessibilityTraits = .button
            button.addAction(UIAction { [weak self, weak presenter, weak comments] _ in
                guard let self, let presenter, let comments else { return }
                self.openSheet(comments: comments, from: presenter)
            }, for: .primaryActionTriggered)
            host.addSubview(button)
            host.addSubview(badge)
            button.translatesAutoresizingMaskIntoConstraints = false
            let bottom = button.bottomAnchor.constraint(equalTo: host.safeAreaLayoutGuide.bottomAnchor)
            NSLayoutConstraint.activate([
                button.leadingAnchor.constraint(
                    equalTo: host.safeAreaLayoutGuide.leadingAnchor,
                    constant: FullScreenFloatingControlChrome.leadingPadding
                ),
                bottom,
                button.widthAnchor.constraint(equalToConstant: FullScreenFloatingControlChrome.controlSize),
                button.heightAnchor.constraint(equalToConstant: FullScreenFloatingControlChrome.controlSize),
                badge.topAnchor.constraint(equalTo: button.topAnchor, constant: -2),
                badge.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: 2),
                badge.heightAnchor.constraint(equalToConstant: 18),
                badge.widthAnchor.constraint(greaterThanOrEqualToConstant: 18),
            ])
            self.button = button
            self.bottom = bottom
        }
        bottom?.constant = -FullScreenReviewCommentStashControl.bottomPadding(
            leadingAccessoryCount: leadingAccessoryCount
        )
        button.accessibilityValue = FullScreenReviewCommentStashControl.accessibilityValue(for: count)
        badge.text = count > 99 ? "99+" : "\(count)"
        badge.textColor = UIColor(palette.bgDark)
        badge.backgroundColor = UIColor(palette.cyan)
        host.bringSubviewToFront(button)
        host.bringSubviewToFront(badge)
        lastCount = count
    }

    private func openSheet(comments: ChatReviewCommentsController, from presenter: UIViewController) {
        if let sheet, sheet.presentingViewController != nil { return }
        // The sheet reads the comments itself, so edits and deletions show
        // while it is open.
        let sheet = ReviewCommentStashViewController(stash: comments, onClose: { [weak self] in self?.closeSheet() })
        Router.present(
            sheet,
            presentation: .sheet.inNavigation(),
            from: presenter,
            theme: HostFactory.root(near: presenter)?.themeStore,
            onDismiss: nil
        )
        self.sheet = sheet
    }

    private func closeSheet() {
        guard let sheet, sheet.presentingViewController != nil else { return }
        Router.finish(sheet)
    }
}

#if DEBUG
/// `OPPI_FILE_MOTION_MARKER=1`: the shown file's path in a colored strip
/// across the top, so motion tests see which page is on screen.
@MainActor
final class FileMotionDebugMarker: UILabel {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["OPPI_FILE_MOTION_MARKER"] == "1"
    }

    init(path: String) {
        super.init(frame: .zero)
        text = path
        textAlignment = .center
        textColor = UIColor(ThemeColorContrast.foreground(for: ThemeRuntimeState.currentThemeID().palette.blue))
        let size = UIFont.preferredFont(forTextStyle: .title2).pointSize
        font = .monospacedSystemFont(ofSize: size, weight: .bold)
        backgroundColor = if path.contains("alpha") {
            .systemRed
        } else if path.contains("gamma") {
            .systemGreen
        } else {
            .systemBlue
        }
        accessibilityIdentifier = "file.motion.page"
        accessibilityValue = path
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width, height: size.height + 20)
    }
}
#endif

/// A text file over 1 MB: its name and size, a warning, and Load File.
@MainActor
final class FileViewerSizeWarningView: UIView {
    private let icon = UIImageView(image: UIImage(systemName: "doc.text"))
    private let name = UILabel()
    private let size = UILabel()
    private let largeFileWarning = WarningRow(
        String(localized: "Large file — loading may be slow"),
        systemImage: "exclamationmark.triangle"
    )
    private let cellularWarning: WarningRow?
    private let button: UIButton

    init(fileName: String, bytes: Int, isExpensiveNetwork: Bool, palette: ThemePalette, onLoad: @escaping () -> Void) {
        cellularWarning = isExpensiveNetwork
            ? WarningRow(
                String(localized: "You're on a cellular connection"),
                systemImage: "antenna.radiowaves.left.and.right"
            )
            : nil
        var load = UIButton.Configuration.borderedProminent()
        load.title = String(localized: "Load File")
        load.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.systemFont(
                ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize,
                weight: .medium
            )
            return attributes
        }
        button = UIButton(configuration: load, primaryAction: UIAction { _ in onLoad() })
        super.init(frame: .zero)

        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 48)

        name.text = fileName
        name.font = .preferredFont(forTextStyle: .headline)
        name.textAlignment = .center
        name.numberOfLines = 0

        size.text = SessionFormatting.byteCount(bytes)
        size.font = UIFont.monospacedDigitSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .subheadline).pointSize,
            weight: .regular
        )

        let warnings = [largeFileWarning, cellularWarning].compactMap { $0?.view }
        let warningStack = UIStackView(arrangedSubviews: warnings)
        warningStack.axis = .vertical
        warningStack.alignment = .center
        warningStack.spacing = 8

        let stack = UIStackView(arrangedSubviews: [icon, name, size, warningStack, button])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 16
        stack.setCustomSpacing(20, after: size)
        stack.setCustomSpacing(24, after: warningStack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            button.widthAnchor.constraint(lessThanOrEqualToConstant: 200),
        ])
        apply(palette)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Colors from `palette`; the viewer calls this again when the theme changes.
    func apply(_ palette: ThemePalette) {
        icon.tintColor = UIColor(palette.comment)
        name.textColor = UIColor(palette.fg)
        size.textColor = UIColor(palette.comment)
        largeFileWarning.setColor(UIColor(palette.yellow))
        cellularWarning?.setColor(UIColor(palette.orange))
        button.configuration?.baseBackgroundColor = UIColor(palette.syntaxKeyword)
    }

    /// A warning symbol and its text, read as one element.
    @MainActor
    private struct WarningRow {
        let view: UIStackView
        private let image: UIImageView
        private let label = UILabel()

        init(_ text: String, systemImage: String) {
            image = UIImageView(image: UIImage(systemName: systemImage))
            image.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .callout)
            label.text = text
            label.font = .preferredFont(forTextStyle: .callout)
            label.numberOfLines = 0
            view = UIStackView(arrangedSubviews: [image, label])
            view.spacing = 6
            view.alignment = .center
            view.isAccessibilityElement = true
            view.accessibilityLabel = text
        }

        func setColor(_ color: UIColor) {
            image.tintColor = color
            label.textColor = color
        }
    }
}
