import UIKit

/// Pi's built-in system prompt, read only, in the full-screen reader: the
/// reader's own back button closes it. Presented bare (`.fullScreen`) by Pi's
/// page; it is a `RouterModalContainer` around the reader.
@MainActor
final class PiDefaultPromptViewController: UIViewController, RouterModalContainer {
    var onDismissed: (() -> Void)?
    private let content: String

    init(content: String) {
        self.content = content
        super.init(nibName: nil, bundle: nil)
        overrideUserInterfaceStyle = ThemeRuntimeState.currentThemeID().preferredColorScheme == .light ? .light : .dark
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        let reader = FullScreenCodeViewController(
            content: .fromText(content, filePath: "Pi-default-system-prompt.md"),
            presentationMode: .embedded(onDismiss: { [weak self] in
                guard let self else { return }
                Router.finish(self)
            })
        )
        addChild(reader)
        reader.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(reader.view)
        NSLayoutConstraint.activate([
            reader.view.topAnchor.constraint(equalTo: view.topAnchor),
            reader.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            reader.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            reader.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        reader.didMove(toParent: self)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Once per presentation: UIKit can report the disappearance again.
        if isBeingDismissed || presentingViewController == nil, let onDismissed {
            self.onDismissed = nil
            onDismissed()
        }
    }
}
