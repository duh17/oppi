import UIKit

enum MarkdownInlineUSDZLayout {
    static let fallbackWidth: CGFloat = 320

    /// Wiki-file syntax has no dimensions, so every mount keeps a 1:1 slot.
    static func reservedHeight(forWidth width: CGFloat) -> CGFloat {
        let resolvedWidth = width.isFinite && width > 0 ? width : fallbackWidth
        return ceil(resolvedWidth)
    }
}

/// Native inline USDZ host for Oppi wiki-file embeds.
///
/// Chat scroll wins until Interact. Done restores scroll. Expand presents a
/// separate `FullScreenUSDZViewController` for the same downloaded file.
@MainActor
final class NativeMarkdownUSDZView: UIView {
    private let statusLabel = UILabel()
    private let retryButton = UIButton(type: .system)
    private let openButton = UIButton(type: .system)
    private let interactButton = UIButton(type: .system)
    private let doneButton = UIButton(type: .system)
    private let expandButton = UIButton(type: .system)
    private let chromeStack = UIStackView()
    private var heightConstraint: NSLayoutConstraint?
    private let sceneView = USDZSceneView()
    private var resolutionTask: Task<Void, Never>?
    private var currentEmbed: MarkdownUSDZEmbed?
    private var currentIdentity: String?
    private var currentHandle: USDZLocalFileStore.Handle?
    private var fileProvider: MarkdownUSDZFileProvider?
    private var renderingMode: ContentRenderingMode = .live
    private var isInteracting = false
    private var disabledScrollView: UIScrollView?
    private var scrollWasEnabled = true
    private(set) var reservedHeight: CGFloat = MarkdownInlineUSDZLayout.reservedHeight(forWidth: .nan)
    private(set) var isStaticFallback = false
#if DEBUG
    var debugIsInteractingForTesting: Bool { isInteracting }
#endif
    var onPreparedGeometry: ((CGFloat) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        resolutionTask?.cancel()
    }

    func prepareForRemoval() {
        resolutionTask?.cancel()
        resolutionTask = nil
        currentIdentity = nil
        restoreScrollIfNeeded()
        isInteracting = false
        removeScene()
        releaseHandle()
    }

    func apply(
        embed: MarkdownUSDZEmbed,
        fileProvider: MarkdownUSDZFileProvider?,
        renderingMode: ContentRenderingMode,
        preferredDisplayWidth: CGFloat?
    ) {
        let width = preferredDisplayWidth.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            ?? (bounds.width > 0 ? bounds.width : MarkdownInlineUSDZLayout.fallbackWidth)
        let identity = [
            embed.reference.target,
            embed.reference.fileCandidatePath ?? "",
            embed.reference.workspaceID ?? "",
            embed.reference.sourceSessionID ?? "",
            String(describing: renderingMode),
        ].joined(separator: "|")
        let nextHeight = MarkdownInlineUSDZLayout.reservedHeight(forWidth: width)

        if identity == currentIdentity {
            applyReservedHeight(nextHeight)
            return
        }

        currentIdentity = identity
        currentEmbed = embed
        self.renderingMode = renderingMode
        self.fileProvider = fileProvider
        restoreScrollIfNeeded()
        isInteracting = false
        resolutionTask?.cancel()
        removeScene()
        releaseHandle()
        applyReservedHeight(nextHeight)

        if renderingMode == .export {
            isStaticFallback = true
            showFallback(
                title: String(localized: "3D scene"),
                detail: embed.displayLabel,
                actionable: false
            )
            return
        }

        isStaticFallback = false
        showLoading(embed: embed)
        guard let fileProvider else {
            showFallback(
                title: String(localized: "Unable to load 3D scene"),
                detail: embed.displayLabel,
                actionable: true
            )
            return
        }

        resolutionTask = Task { [weak self] in
            do {
                let handle = try await fileProvider(embed)
                guard let self, !Task.isCancelled, self.currentIdentity == identity else {
                    await USDZLocalFileStore.shared.release(handle)
                    return
                }
                self.currentHandle = handle
                self.installScene(handle: handle)
            } catch {
                guard let self, !Task.isCancelled, self.currentIdentity == identity else { return }
                self.showFallback(
                    title: String(localized: "Unable to load 3D scene"),
                    detail: embed.displayLabel,
                    actionable: true
                )
            }
        }
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: reservedHeight)
    }

    private func setupViews() {
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = UIColor(ThemeRuntimeState.currentPalette().bgHighlight)
        layer.cornerRadius = 8
        clipsToBounds = true
        accessibilityIdentifier = "markdown-usdz"

        sceneView.translatesAutoresizingMaskIntoConstraints = false
        sceneView.isHidden = true
        sceneView.onLoadFailed = { [weak self] in
            self?.showFallback(
                title: String(localized: "Unable to load 3D scene"),
                detail: self?.currentEmbed?.displayLabel ?? "",
                actionable: true
            )
        }
        addSubview(sceneView)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.font = UIFont.preferredFont(forTextStyle: .caption1)
        statusLabel.textColor = UIColor(ThemeRuntimeState.currentPalette().comment)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 3

        configure(retryButton, title: String(localized: "Retry"), systemImage: "arrow.clockwise")
        retryButton.accessibilityIdentifier = "markdown-usdz-retry"
        retryButton.addAction(UIAction { [weak self] _ in self?.retry() }, for: .touchUpInside)

        configure(openButton, title: String(localized: "Open file"), systemImage: "doc")
        openButton.accessibilityIdentifier = "markdown-usdz-open"
        openButton.addAction(UIAction { [weak self] _ in self?.openFile() }, for: .touchUpInside)

        configure(interactButton, title: String(localized: "Interact"), systemImage: "hand.draw")
        interactButton.accessibilityIdentifier = "markdown-usdz-interact"
        interactButton.addAction(UIAction { [weak self] _ in self?.setInteracting(true) }, for: .touchUpInside)

        configure(doneButton, title: String(localized: "Done"), systemImage: "checkmark")
        doneButton.accessibilityIdentifier = "markdown-usdz-done"
        doneButton.addAction(UIAction { [weak self] _ in self?.setInteracting(false) }, for: .touchUpInside)

        configure(expandButton, title: String(localized: "Expand"), systemImage: "arrow.up.left.and.arrow.down.right")
        expandButton.accessibilityIdentifier = "markdown-usdz-expand"
        expandButton.addAction(UIAction { [weak self] _ in self?.expand() }, for: .touchUpInside)

        let actionRow = UIStackView(arrangedSubviews: [retryButton, openButton])
        actionRow.axis = .horizontal
        actionRow.spacing = 8
        actionRow.alignment = .center

        let statusStack = UIStackView(arrangedSubviews: [statusLabel, actionRow])
        statusStack.translatesAutoresizingMaskIntoConstraints = false
        statusStack.axis = .vertical
        statusStack.alignment = .center
        statusStack.spacing = 8
        addSubview(statusStack)

        chromeStack.translatesAutoresizingMaskIntoConstraints = false
        chromeStack.axis = .horizontal
        chromeStack.spacing = 8
        chromeStack.alignment = .center
        chromeStack.addArrangedSubview(interactButton)
        chromeStack.addArrangedSubview(doneButton)
        chromeStack.addArrangedSubview(expandButton)
        addSubview(chromeStack)

        heightConstraint = heightAnchor.constraint(equalToConstant: reservedHeight)
        heightConstraint?.priority = .required
        heightConstraint?.isActive = true

        NSLayoutConstraint.activate([
            sceneView.leadingAnchor.constraint(equalTo: leadingAnchor),
            sceneView.trailingAnchor.constraint(equalTo: trailingAnchor),
            sceneView.topAnchor.constraint(equalTo: topAnchor),
            sceneView.bottomAnchor.constraint(equalTo: bottomAnchor),
            statusStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            statusStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusStack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 12),
            statusStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            chromeStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            chromeStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
    }

    private func configure(_ button: UIButton, title: String, systemImage: String) {
        var configuration = UIButton.Configuration.bordered()
        configuration.title = title
        configuration.image = UIImage(systemName: systemImage)
        configuration.imagePadding = 6
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = UIFont.preferredFont(forTextStyle: .caption1)
            return outgoing
        }
        button.configuration = configuration
    }

    private func applyReservedHeight(_ height: CGFloat) {
        reservedHeight = height
        heightConstraint?.constant = height
        invalidateIntrinsicContentSize()
        onPreparedGeometry?(height)
    }

    private func showLoading(embed: MarkdownUSDZEmbed) {
        statusLabel.text = String(localized: "Loading 3D scene")
        statusLabel.isHidden = false
        retryButton.isHidden = true
        openButton.isHidden = true
        chromeStack.isHidden = true
        accessibilityLabel = embed.displayLabel
    }

    private func showFallback(title: String, detail: String, actionable: Bool) {
        restoreScrollIfNeeded()
        isInteracting = false
        removeScene()
        statusLabel.text = "\(title)\n\(detail)"
        statusLabel.isHidden = false
        retryButton.isHidden = !actionable || isStaticFallback
        openButton.isHidden = !actionable || isStaticFallback
        chromeStack.isHidden = true
        accessibilityLabel = title
    }

    private func installScene(handle: USDZLocalFileStore.Handle) {
        statusLabel.isHidden = true
        retryButton.isHidden = true
        openButton.isHidden = true
        chromeStack.isHidden = false
        doneButton.isHidden = true
        interactButton.isHidden = false
        expandButton.isHidden = false

        sceneView.isInteractive = false
        sceneView.accessibilityLabel = currentEmbed?.displayLabel
        sceneView.isHidden = false
        sceneView.show(fileURL: handle.url)
        accessibilityLabel = currentEmbed?.displayLabel
    }

    private func setInteracting(_ interacting: Bool) {
        guard renderingMode != .export, currentHandle != nil else { return }
        isInteracting = interacting
        sceneView.isInteractive = interacting
        doneButton.isHidden = !interacting
        interactButton.isHidden = interacting
        if interacting {
            disableEnclosingScrollView()
        } else {
            restoreScrollIfNeeded()
        }
    }

    private func retry() {
        guard let embed = currentEmbed else { return }
        currentIdentity = nil
        apply(
            embed: embed,
            fileProvider: fileProvider,
            renderingMode: renderingMode,
            preferredDisplayWidth: bounds.width
        )
    }

    private func openFile() {
        guard let reference = currentEmbed?.reference else { return }
        AppRootEnvironment.near(self)?.opener.open(.resourceReference(reference))
    }

    private func expand() {
        guard renderingMode != .export else { return }
        guard let embed = currentEmbed else { return }
        FullScreenUSDZPresenter.present(
            from: self,
            embed: embed,
            handle: currentHandle,
            fileProvider: fileProvider
        )
    }

    private func removeScene() {
        sceneView.clear()
        sceneView.isHidden = true
        sceneView.isInteractive = false
    }

    private func releaseHandle() {
        guard let handle = currentHandle else { return }
        currentHandle = nil
        Task { await USDZLocalFileStore.shared.release(handle) }
    }

    private func disableEnclosingScrollView() {
        guard disabledScrollView == nil else { return }
        var current: UIView? = superview
        while let view = current {
            if let scroll = view as? UIScrollView {
                scrollWasEnabled = scroll.isScrollEnabled
                scroll.isScrollEnabled = false
                disabledScrollView = scroll
                return
            }
            current = view.superview
        }
    }

    private func restoreScrollIfNeeded() {
        guard let scroll = disabledScrollView else { return }
        scroll.isScrollEnabled = scrollWasEnabled
        disabledScrollView = nil
    }
}

enum FullScreenUSDZPresenter {
    @MainActor
    static func present(
        from view: UIView,
        embed: MarkdownUSDZEmbed,
        handle: USDZLocalFileStore.Handle?,
        fileProvider: MarkdownUSDZFileProvider?
    ) {
        guard let presenter = nearestViewController(from: view) else { return }
        let screen = FullScreenUSDZViewController(
            embed: embed,
            initialHandle: handle,
            fileProvider: fileProvider
        )
        Router.present(screen, presentation: .fullScreen.inNavigation(), from: presenter)
    }

    @MainActor
    private static func nearestViewController(from view: UIView) -> UIViewController? {
        var current: UIResponder? = view
        while let responder = current {
            if let controller = responder as? UIViewController {
                return controller
            }
            current = responder.next
        }
        return nil
    }
}

/// The expanded USDZ scene: the downloaded file (or one fetched through the
/// provider) with inspect gestures on, under a navigation bar with Done.
/// Presented through the router; it holds its own retain on the file for as
/// long as it is on screen.
@MainActor
final class FullScreenUSDZViewController: UIViewController {
    private let embed: MarkdownUSDZEmbed
    private let initialHandle: USDZLocalFileStore.Handle?
    private let fileProvider: MarkdownUSDZFileProvider?
    private let sceneView = USDZSceneView()
    private let statusView = UIContentUnavailableView(loadState: .loading(nil))
    private var handle: USDZLocalFileStore.Handle?
    private var loadTask: Task<Void, Never>?

    init(
        embed: MarkdownUSDZEmbed,
        initialHandle: USDZLocalFileStore.Handle?,
        fileProvider: MarkdownUSDZFileProvider?
    ) {
        self.embed = embed
        self.initialHandle = initialHandle
        self.fileProvider = fileProvider
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.accessibilityIdentifier = "markdown-usdz-fullscreen"
        navigationItem.title = embed.displayLabel
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .done,
            primaryAction: UIAction { [weak self] _ in
                guard let self else { return }
                Router.finish(self)
            }
        )

        sceneView.isInteractive = true
        sceneView.accessibilityLabel = embed.displayLabel
        sceneView.onLoadFailed = { [weak self] in self?.showFailure() }
        sceneView.isHidden = true

        for subview in [sceneView, statusView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
            NSLayoutConstraint.activate([
                subview.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                subview.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                subview.topAnchor.constraint(equalTo: view.topAnchor),
                subview.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
        }
    }

    override func updateProperties() {
        super.updateProperties()
        view.backgroundColor = .themeBg
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        startLoading()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        loadTask?.cancel()
        loadTask = nil
        sceneView.clear()
        guard let handle else { return }
        self.handle = nil
        Task { await USDZLocalFileStore.shared.release(handle) }
    }

    private func startLoading() {
        loadTask?.cancel()
        loadTask = Task { [weak self] in await self?.load() }
    }

    private func load() async {
        if handle != nil { return }
        showLoading()
        if let initialHandle {
            await USDZLocalFileStore.shared.retain(initialHandle)
            guard !Task.isCancelled else {
                await USDZLocalFileStore.shared.release(initialHandle)
                return
            }
            show(initialHandle)
            return
        }
        guard let fileProvider else {
            showFailure()
            return
        }
        do {
            let loaded = try await fileProvider(embed)
            guard !Task.isCancelled else {
                await USDZLocalFileStore.shared.release(loaded)
                return
            }
            show(loaded)
        } catch {
            guard !Task.isCancelled else { return }
            showFailure()
        }
    }

    private func show(_ handle: USDZLocalFileStore.Handle) {
        self.handle = handle
        statusView.isHidden = true
        sceneView.isHidden = false
        sceneView.show(fileURL: handle.url)
    }

    private func showLoading() {
        sceneView.isHidden = true
        statusView.isHidden = false
        statusView.configuration = UIContentUnavailableConfiguration.loadState(
            .loading(String(localized: "Loading 3D scene")),
            palette: ThemeRuntimeState.currentPalette()
        )
    }

    private func showFailure() {
        sceneView.clear()
        sceneView.isHidden = true
        statusView.isHidden = false
        var configuration = UIContentUnavailableConfiguration.loadState(
            .failed(
                title: String(localized: "Unable to load 3D scene"),
                message: embed.displayLabel,
                retry: RetryAction { [weak self] in self?.startLoading() }
            ),
            palette: ThemeRuntimeState.currentPalette()
        )
        var open = UIButton.Configuration.bordered()
        open.title = String(localized: "Open file")
        configuration.secondaryButton = open
        configuration.secondaryButtonProperties.primaryAction = UIAction { [weak self] _ in
            guard let self else { return }
            AppRootEnvironment.near(self)?.opener.open(.resourceReference(embed.reference))
        }
        statusView.configuration = configuration
    }
}
