import UIKit

/// One text an extension gives the model, pushed from its detail or tool page: a
/// prompt section's Markdown, or a tool's JSON Schema. It is the full-screen
/// reader with its own floating Back, so the stack's bar hides while it shows.
/// The text is in memory (the detail answer), so there is nothing to load.
@MainActor
final class ServerExtensionReaderViewController: UIViewController, NavigationBarHiding {
    /// What the reader shows.
    let content: FullScreenCodeContent
    private let root: AppRootEnvironment
    private var reader: FullScreenCodeViewController?

    /// `title` names the page in the stack's Back history; the reader itself is
    /// immersive and draws no title.
    init(title: String, content: FullScreenCodeContent, root: AppRootEnvironment) {
        self.content = content
        self.root = root
        super.init(nibName: nil, bundle: nil)
        self.title = title
        traitOverrides.appRootEnvironment = root
        navigationItem.largeTitleDisplayMode = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// A prompt section as its plugin writes it. The footer says what the
    /// reader cannot: another plugin's wrap may change it in a session. Raw
    /// shows the section's own text, without the footer.
    static func section(named name: String, text: String, root: AppRootEnvironment) -> ServerExtensionReaderViewController {
        let footer = String(localized: "As the plugin writes it; a wrapping plugin can change what a session sees.")
        return ServerExtensionReaderViewController(
            title: name,
            content: .markdown(content: "\(text)\n\n---\n\n*\(footer)*", filePath: name, rawText: text),
            root: root
        )
    }

    /// A tool's JSON Schema, pretty-printed with sorted keys.
    static func schema(
        ofTool name: String,
        schema: JSONValue,
        root: AppRootEnvironment
    ) -> ServerExtensionReaderViewController {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let json = (try? encoder.encode(schema)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return ServerExtensionReaderViewController(
            title: String(localized: "\(name) JSON Schema"),
            content: .code(content: json, language: "json", filePath: "\(name).schema.json", startLine: 1),
            root: root
        )
    }

    /// The reader draws its own bar.
    var hidesNavigationBar: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        let reader = FullScreenCodeViewController(
            content: content,
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
            reader.view.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            reader.view.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            reader.view.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
        ])
        reader.didMove(toParent: self)
        self.reader = reader
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(true, animated: animated)
    }

    override func updateProperties() {
        super.updateProperties()
        view.backgroundColor = root.themeStore.backgroundColor
        reader?.applyThemeIfNeeded(root.themeStore.activeThemeID)
    }
}
