import UIKit

/// A guided control session for one definition, as a router sheet: what it
/// does, Cancel, and the guided composer. The presenter presents it with
/// `.sheet.inNavigation()` as a `RouterScreen.controller`.
@MainActor
final class GuidedControlSessionViewController: UIViewController {
    private let configuration: GuidedControlComposerConfiguration
    private let root: AppRootEnvironment
    private let composer: GuidedControlComposerController
    private let emptyState = UIContentUnavailableView(configuration: UIContentUnavailableConfiguration.empty())

    /// `connection` is the server the session starts on (the active one when
    /// nil). `onSessionPrepared` takes the prepared session; without it the
    /// sheet closes and the app opens the session.
    init(
        configuration: GuidedControlComposerConfiguration,
        root: AppRootEnvironment,
        connection: (@MainActor () -> ServerConnection)? = nil,
        onSessionPrepared: ((WorkspaceSessionNavTarget) -> Void)? = nil
    ) {
        self.configuration = configuration
        self.root = root
        composer = GuidedControlComposerController(configuration: configuration, root: root, connection: connection)
        super.init(nibName: nil, bundle: nil)
        traitOverrides.appRootEnvironment = root
        let navigation = root.navigation
        composer.model.onSessionPrepared = { [weak self] target in
            if let onSessionPrepared {
                onSessionPrepared(target)
                return
            }
            if let self { Router.finish(self) }
            Task { @MainActor in
                // Open the session once the sheet's dismissal has started.
                await Task.yield()
                navigation.openWorkspaceSession(target)
            }
        }
        title = Self.title(configuration)
        navigationItem.largeTitleDisplayMode = .never
        let cancel = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in
            guard let self else { return }
            Router.finish(self)
        })
        navigationItem.leftBarButtonItem = cancel
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    static func title(_ configuration: GuidedControlComposerConfiguration) -> String {
        let subject = configuration.targetName ?? configuration.domain.title
        return configuration.intent == .create ? "Create \(subject)" : "Revise \(subject)"
    }

    private static func systemImage(_ domain: ControlSessionDomain) -> String {
        switch domain {
        case .agents: "person.crop.circle.badge.questionmark"
        case .extensions: "puzzlepiece.extension"
        case .schedules: "calendar.badge.clock"
        case .skills: "hammer"
        case .themes: "paintpalette"
        case .workspaces: "folder.badge.gearshape"
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyState)
        composer.install(in: self)
        NSLayoutConstraint.activate([
            emptyState.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            emptyState.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            emptyState.bottomAnchor.constraint(equalTo: composer.view.topAnchor),
        ])
        // The keyboard leaves with a tap outside the composer.
        let tap = UITapGestureRecognizer(target: self, action: #selector(endEditing))
        tap.cancelsTouchesInView = false
        emptyState.addGestureRecognizer(tap)
    }

    @objc private func endEditing() {
        view.endEditing(true)
    }

    override func updateProperties() {
        super.updateProperties()
        let theme = root.themeStore
        let palette = theme.activeThemeID.palette
        overrideUserInterfaceStyle = theme.userInterfaceStyle
        view.backgroundColor = theme.backgroundColor
        emptyState.configuration = ControlScreenList.unavailable(
            title ?? "",
            systemImage: Self.systemImage(configuration.domain),
            description: "Describe the outcome you want. Oppi will inspect the current definition and clarify anything ambiguous before changing it.",
            palette: palette
        )
    }
}
