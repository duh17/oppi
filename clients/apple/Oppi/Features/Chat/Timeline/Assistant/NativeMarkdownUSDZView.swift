import Combine
import RealityKit
import SwiftUI
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
/// separate RealityKit scene from the same downloaded file.
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
    private let interactChrome = USDZInteractChrome()
    private var sceneHost: UIHostingController<USDZRealityCanvas>?
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
                self.installScene(handle: handle, interactive: false)
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

    private func installScene(handle: USDZLocalFileStore.Handle, interactive: Bool) {
        statusLabel.isHidden = true
        retryButton.isHidden = true
        openButton.isHidden = true
        chromeStack.isHidden = false
        doneButton.isHidden = !interactive
        interactButton.isHidden = interactive
        expandButton.isHidden = false

        interactChrome.cameraControlsEnabled = interactive
        let canvas = USDZRealityCanvas(
            fileURL: handle.url,
            interactChrome: interactChrome,
            onLoadFailed: { [weak self] in
                self?.showFallback(
                    title: String(localized: "Unable to load 3D scene"),
                    detail: self?.currentEmbed?.displayLabel ?? "",
                    actionable: true
                )
            }
        )
        let host = UIHostingController(rootView: canvas)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.backgroundColor = .clear
        host.view.isUserInteractionEnabled = interactive
        if let sceneHost {
            sceneHost.willMove(toParent: nil)
            sceneHost.view.removeFromSuperview()
            sceneHost.removeFromParent()
        }
        if let parent = nearestViewController() {
            parent.addChild(host)
            addSubview(host.view)
            sendSubviewToBack(host.view)
            host.didMove(toParent: parent)
        } else {
            addSubview(host.view)
            sendSubviewToBack(host.view)
        }
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.view.topAnchor.constraint(equalTo: topAnchor),
            host.view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        sceneHost = host
        accessibilityLabel = currentEmbed?.displayLabel
    }

    private func setInteracting(_ interacting: Bool) {
        guard renderingMode != .export, currentHandle != nil else { return }
        isInteracting = interacting
        interactChrome.cameraControlsEnabled = interacting
        sceneHost?.view.isUserInteractionEnabled = interacting
        doneButton.isHidden = !interacting
        interactButton.isHidden = interacting
        if interacting {
            disableEnclosingScrollView()
        } else {
            restoreScrollIfNeeded()
        }
    }

    private func nearestViewController() -> UIViewController? {
        var current: UIResponder? = self
        while let responder = current {
            if let controller = responder as? UIViewController {
                return controller
            }
            current = responder.next
        }
        return nil
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
        NotificationCenter.default.post(name: .resourceReferenceTapped, object: reference)
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
        sceneHost?.willMove(toParent: nil)
        sceneHost?.view.removeFromSuperview()
        sceneHost?.removeFromParent()
        sceneHost = nil
        interactChrome.cameraControlsEnabled = false
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
        let root = FullScreenUSDZView(
            embed: embed,
            initialHandle: handle,
            fileProvider: fileProvider
        )
        let host = UIHostingController(rootView: root)
        host.modalPresentationStyle = .fullScreen
        presenter.present(host, animated: true)
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

struct FullScreenUSDZView: View {
    let embed: MarkdownUSDZEmbed
    let initialHandle: USDZLocalFileStore.Handle?
    let fileProvider: MarkdownUSDZFileProvider?
    @Environment(\.dismiss) private var dismiss
    @State private var handle: USDZLocalFileStore.Handle?
    @State private var didFail = false
    @State private var isLoading = false

    var body: some View {
        ZStack {
            Color(ThemeRuntimeState.currentPalette().bg).ignoresSafeArea()
            if let handle {
                USDZRealityCanvas(fileURL: handle.url, cameraControlsEnabled: true)
                    .ignoresSafeArea()
            } else if didFail {
                ContentUnavailableView {
                    Label("Unable to load 3D scene", systemImage: "cube")
                } description: {
                    Text(embed.displayLabel)
                } actions: {
                    Button("Retry") { Task { await load() } }
                    Button("Open file") {
                        NotificationCenter.default.post(
                            name: .resourceReferenceTapped,
                            object: embed.reference
                        )
                    }
                }
            } else {
                ProgressView("Loading 3D scene")
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                Text(embed.displayLabel)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
        }
        .accessibilityIdentifier("markdown-usdz-fullscreen")
        .task {
            await load()
        }
        .onDisappear {
            releaseLoadedHandle()
        }
    }

    private func releaseLoadedHandle() {
        guard let handle else { return }
        self.handle = nil
        Task { await USDZLocalFileStore.shared.release(handle) }
    }

    private func load() async {
        didFail = false
        if handle != nil { return }
        if let initialHandle {
            await USDZLocalFileStore.shared.retain(initialHandle)
            if Task.isCancelled {
                await USDZLocalFileStore.shared.release(initialHandle)
                return
            }
            handle = initialHandle
            return
        }
        guard let fileProvider else {
            didFail = true
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            handle = try await fileProvider(embed)
        } catch {
            didFail = true
        }
    }
}

/// File-browser and full-screen USDZ canvas. Camera controls are on immediately.
struct FileBrowserUSDZPreview: View {
    let fileURL: URL
    var accessibilityName: String = "3D scene"

    var body: some View {
        USDZRealityCanvas(fileURL: fileURL, cameraControlsEnabled: true)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("file-browser-usdz")
            .accessibilityLabel(accessibilityName)
    }
}

/// FileContentView USDZ host. Fetches authenticated bytes, then RealityView.
struct USDZFileView: View {
    let filePath: String?
    var workspaceID: String?
    var fetchWorkspaceFile: ((_ workspaceID: String, _ path: String) async throws -> Data)?
    var fetchHostFile: ((_ path: String) async throws -> Data)?
    @State private var handle: USDZLocalFileStore.Handle?
    @State private var didFail = false

    var body: some View {
        Group {
            if let handle {
                FileBrowserUSDZPreview(
                    fileURL: handle.url,
                    accessibilityName: displayName
                )
            } else if didFail {
                ContentUnavailableView(
                    "Unable to load 3D scene",
                    systemImage: "cube",
                    description: Text(displayName)
                )
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: filePath) {
            await load()
        }
        .onDisappear {
            releaseHandle()
        }
    }

    private var displayName: String {
        guard let filePath, !filePath.isEmpty else { return "3D scene" }
        return (filePath as NSString).lastPathComponent
    }

    private func load() async {
        didFail = false
        releaseHandle()
        guard let path = filePath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            didFail = true
            return
        }
        let data: Data?
        do {
            if path.hasPrefix("/") || path.hasPrefix("~"), let fetchHostFile {
                data = try await fetchHostFile(path)
            } else if let workspaceID, !workspaceID.isEmpty, let fetchWorkspaceFile {
                data = try await fetchWorkspaceFile(workspaceID, path)
            } else if let fetchHostFile {
                data = try await fetchHostFile(path)
            } else {
                didFail = true
                return
            }
        } catch {
            didFail = true
            return
        }
        guard let data, !data.isEmpty else {
            didFail = true
            return
        }
        let key = USDZLocalFileStore.cacheKey(
            kind: path.hasPrefix("/") || path.hasPrefix("~") ? .hostFile : .workspaceFile,
            workspaceID: workspaceID,
            sessionID: nil,
            worktreeID: nil,
            path: path
        )
        do {
            let stored = try await USDZLocalFileStore.shared.store(key: key, data: data)
            guard !Task.isCancelled else {
                await USDZLocalFileStore.shared.release(stored)
                return
            }
            handle = stored
        } catch {
            didFail = true
        }
    }

    private func releaseHandle() {
        guard let handle else { return }
        self.handle = nil
        Task { await USDZLocalFileStore.shared.release(handle) }
    }
}

/// Apple `CameraControls` is one mode at a time (orbit *or* pan *or* dolly).
/// Inspect uses 1-finger orbit, pinch zoom, and 2-finger pan on the model.
@MainActor
final class USDZInspectState: ObservableObject {
    @Published var yaw: Float = 0
    @Published var pitch: Float = 0
    @Published var zoom: Float = 1
    @Published var pan: SIMD2<Float> = .zero

    func apply(to gimbal: Entity?) {
        guard let gimbal else { return }
        let pitchQ = simd_quatf(angle: pitch, axis: SIMD3<Float>(1, 0, 0))
        let yawQ = simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0))
        gimbal.orientation = pitchQ * yawQ
        gimbal.scale = SIMD3<Float>(repeating: zoom)
        gimbal.position = SIMD3<Float>(pan.x, pan.y, 0)
    }

    func clamp() {
        let nextPitch = min(1.2, max(-1.2, pitch))
        let nextZoom = min(3, max(0.35, zoom))
        let nextPan = SIMD2(min(1.6, max(-1.6, pan.x)), min(1.6, max(-1.6, pan.y)))
        if nextPitch != pitch { pitch = nextPitch }
        if nextZoom != zoom { zoom = nextZoom }
        if nextPan != pan { pan = nextPan }
    }
}

@MainActor
final class USDZInteractChrome: ObservableObject {
    @Published var cameraControlsEnabled: Bool

    init(cameraControlsEnabled: Bool = false) {
        self.cameraControlsEnabled = cameraControlsEnabled
    }
}

struct USDZRealityCanvas: View {
    let fileURL: URL
    var onLoadFailed: (() -> Void)? = nil
    @ObservedObject private var interactChrome: USDZInteractChrome
    @StateObject private var inspect = USDZInspectState()
    @State private var didFail = false

    init(
        fileURL: URL,
        cameraControlsEnabled: Bool,
        onLoadFailed: (() -> Void)? = nil
    ) {
        self.fileURL = fileURL
        self.onLoadFailed = onLoadFailed
        self._interactChrome = ObservedObject(
            wrappedValue: USDZInteractChrome(cameraControlsEnabled: cameraControlsEnabled)
        )
    }

    init(
        fileURL: URL,
        interactChrome: USDZInteractChrome,
        onLoadFailed: (() -> Void)? = nil
    ) {
        self.fileURL = fileURL
        self.onLoadFailed = onLoadFailed
        self._interactChrome = ObservedObject(wrappedValue: interactChrome)
    }

    var body: some View {
        ZStack {
            if didFail {
                ContentUnavailableView(
                    "Unable to load 3D scene",
                    systemImage: "cube",
                    description: Text(fileURL.lastPathComponent)
                )
            } else {
                RealityView { content in
                    do {
                        let model = try await Entity(contentsOf: fileURL, withName: nil)
                        content.add(Self.inspectionRoot(for: model))
                    } catch {
                        didFail = true
                        onLoadFailed?()
                    }
                } update: { content in
                    inspect.apply(
                        to: content.entities.first?.findEntity(named: Self.gimbalName)
                    )
                } placeholder: {
                    ProgressView()
                }
                .realityViewCameraControls(.none)
                .realityViewLayoutBehavior(.centered)
                .overlay {
                    if interactChrome.cameraControlsEnabled {
                        USDZInspectGestureView(state: inspect)
                            .accessibilityHidden(true)
                    }
                }
            }
        }
        .accessibilityAddTraits(.allowsDirectInteraction)
        .accessibilityHint(String(localized: "Drag to orbit, pinch to zoom, two fingers to pan"))
    }

    private static let gimbalName = "usdz-gimbal"

    /// Do not call `visualBounds` in `make` — it can hang USDZ loads on iOS.
    /// `.centered` measures bounds after `make` returns.
    @discardableResult
    private static func inspectionRoot(for model: Entity) -> Entity {
        let gimbal = Entity()
        gimbal.name = gimbalName
        gimbal.addChild(model)
        let root = Entity()
        root.name = "usdz-root"
        root.addChild(gimbal)
        return root
    }
}

/// 1-finger orbit, pinch zoom, 2-finger pan. Does not use exclusive CameraControls.
private struct USDZInspectGestureView: UIViewRepresentable {
    @ObservedObject var state: USDZInspectState

    func makeCoordinator() -> Coordinator {
        Coordinator(state: state)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isAccessibilityElement = false
        view.accessibilityIdentifier = "markdown-usdz-gestures"

        let orbit = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleOrbit(_:))
        )
        orbit.minimumNumberOfTouches = 1
        orbit.maximumNumberOfTouches = 1
        orbit.name = "usdz-orbit"

        let pan = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePan(_:))
        )
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        pan.name = "usdz-pan"

        let pinch = UIPinchGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePinch(_:))
        )
        pinch.name = "usdz-zoom"

        view.addGestureRecognizer(orbit)
        view.addGestureRecognizer(pan)
        view.addGestureRecognizer(pinch)
        pinch.delegate = context.coordinator
        pan.delegate = context.coordinator
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.state = state
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var state: USDZInspectState
        private var pinchStart: Float = 1

        init(state: USDZInspectState) {
            self.state = state
        }

        @objc func handleOrbit(_ gesture: UIPanGestureRecognizer) {
            let translation = gesture.translation(in: gesture.view)
            gesture.setTranslation(.zero, in: gesture.view)
            state.yaw += Float(translation.x) * 0.01
            state.pitch -= Float(translation.y) * 0.01
            state.clamp()
        }

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            let translation = gesture.translation(in: gesture.view)
            gesture.setTranslation(.zero, in: gesture.view)
            state.pan += SIMD2(
                Float(translation.x) * 0.004,
                Float(-translation.y) * 0.004
            )
            state.clamp()
        }

        @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            if gesture.state == .began {
                pinchStart = state.zoom
            }
            state.zoom = pinchStart * Float(gesture.scale)
            state.clamp()
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            gestureRecognizer.name == "usdz-zoom" && other.name == "usdz-pan"
                || gestureRecognizer.name == "usdz-pan" && other.name == "usdz-zoom"
        }
    }
}
