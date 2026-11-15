import UIKit

/// The sides of a file with no text diff, from the server's `nonText` flags.
enum NonTextDiffSides {
    /// One version of the file. A nil `revision` is the working tree.
    struct Side: Equatable {
        let title: String
        let revision: String?
    }

    /// The versions that exist, oldest first: Before at `beforeRevision`, After
    /// at `afterRevision` (nil: the working tree).
    static func resolve(
        _ nonText: WorkspaceReviewDiffResponse.NonText,
        beforeRevision: String,
        afterRevision: String?
    ) -> [Side] {
        var sides: [Side] = []
        if nonText.before {
            sides.append(Side(title: String(localized: "Before"), revision: beforeRevision))
        }
        if nonText.after {
            sides.append(Side(title: String(localized: "After"), revision: afterRevision))
        }
        return sides
    }
}

/// What a diff shows for a file it cannot render as text: the file itself, in
/// the file viewer, for each version that exists. With both, a Before/After
/// control switches between them and After shows first.
@MainActor
final class NonTextDiffPreviewViewController: UIViewController {
    struct Configuration {
        let workspaceId: String
        let path: String
        let sides: [NonTextDiffSides.Side]
        var worktreeId: String? = nil
        var serverId: String? = nil
        var sessionId: String? = nil
        var reviewCommentSelectionScope: ReviewCommentSelectionScope? = nil
    }

    private let configuration: Configuration
    private let services: FileViewerViewController.Services
    private let contentView = UIView()
    /// The version on screen; its bar's offers (Share) go on the host's bar.
    private(set) var viewer: FileViewerViewController?
    /// Runs when another version replaces the viewer, so the host reads its bar again.
    var onViewerChange: (() -> Void)?
    private var shownIndex: Int?

    init(configuration: Configuration, services: FileViewerViewController.Services) {
        self.configuration = configuration
        self.services = services
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        let stack = UIStackView()
        stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        let lastIndex = configuration.sides.count - 1
        if configuration.sides.count > 1 {
            let control = UISegmentedControl(items: configuration.sides.map(\.title))
            control.selectedSegmentIndex = lastIndex
            control.accessibilityIdentifier = "nonTextDiff.side"
            control.accessibilityLabel = String(localized: "Version")
            control.addAction(UIAction { [weak self, weak control] _ in
                guard let self, let control else { return }
                show(control.selectedSegmentIndex)
            }, for: .valueChanged)
            stack.addArrangedSubview(ReviewSegmentedControlSlot.wrap(control))
        }
        stack.addArrangedSubview(contentView)
        show(max(lastIndex, 0))
    }

    override func updateProperties() {
        super.updateProperties()
        let themeID = AppRootEnvironment.near(self)?.themeStore.activeThemeID ?? ThemeRuntimeState.currentThemeID()
        view.backgroundColor = themeID.palette.ui.bgDark
    }

    /// Mounts the viewer for one version, replacing the one on screen.
    private func show(_ index: Int) {
        guard configuration.sides.indices.contains(index), index != shownIndex else { return }
        shownIndex = index
        if let viewer {
            viewer.willMove(toParent: nil)
            viewer.view.removeFromSuperview()
            viewer.removeFromParent()
        }
        let next = FileViewerViewController(
            configuration: FileViewerViewController.Configuration(
                workspaceId: configuration.workspaceId,
                worktreeId: configuration.worktreeId,
                serverId: configuration.serverId,
                filePath: configuration.path,
                fileName: configuration.path.lastPathComponentForDisplay,
                sessionId: configuration.sessionId,
                chromeMode: .treePane,
                allowsHorizontalBackSwipe: false,
                showsReviewCommentStash: false,
                reviewCommentSelectionScope: configuration.reviewCommentSelectionScope,
                revision: configuration.sides[index].revision
            ),
            services: services
        )
        addChild(next)
        next.view.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(next.view)
        NSLayoutConstraint.activate([
            next.view.topAnchor.constraint(equalTo: contentView.topAnchor),
            next.view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            next.view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            next.view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])
        next.didMove(toParent: self)
        viewer = next
        onViewerChange?()
    }
}
