import PaperKit
import PencilKit
import SwiftUI
import UIKit

/// Full-screen PaperKit markup host shared by the composer and viewers.
final class PaperMarkupCanvasHostController: UIViewController {
    private let background: PaperMarkupCanvasSession.Background
    private let onCancel: (() -> Void)?
    private let destination: ComposerCanvasDestination?
    private let onDeliveryAccepted: (() -> Void)?
    private let supportedFeatureSet: FeatureSet
    private var isDirty = false
    private var paperViewController: PaperMarkupViewController?
    private var toolPicker: PKToolPicker?
    private var paperBottomConstraint: NSLayoutConstraint?
    private var canApplyInitialFit = false
    private var didApplyInitialFit = false
    private var markupChangeRelay: PaperMarkupChangeRelay?
    private var markupInsertRelay: PaperMarkupInsertRelay?
    private var isExporting = false
    private var isDismissed = false
    private var exportTask: Task<Void, Never>?
    private var backgroundImageView: UIImageView?
    private var copiedBackgroundImage: UIImage?
    private var progressOverlay: UIView?
    private var shouldFailNextExportForTesting = false
    private var isRestoringInkingTool = false
    private var shouldHoldNextExportForTesting = false
    private var exportHoldForTesting: CheckedContinuation<Void, Never>?
    private var exportStartedHoldForTesting: CheckedContinuation<Void, Never>?
    private(set) var didDismissForTesting = false
    private(set) var lastFailureMessageForTesting: String?

    var cancelDisposition: PaperMarkupCanvasSession.CancelDisposition {
        PaperMarkupCanvasSession.cancelDisposition(isDirty: isDirty || hasRenderedMarkup)
    }

    private var hasRenderedMarkup: Bool {
        guard let frame = paperViewController?.markup?.contentsRenderFrame else { return false }
        return !frame.isNull && !frame.isEmpty && frame.width > 0 && frame.height > 0
    }

    var usesCopiedBackgroundImage: Bool {
        copiedBackgroundImage != nil
    }

    var backgroundImageForTesting: UIImage? {
        copiedBackgroundImage
    }

    var destinationSessionIdForTesting: String? {
        destination?.sessionId
    }

    var isShowingExportProgressForTesting: Bool {
        isExporting
    }

    var markupBoundsForTesting: CGRect? {
        paperViewController?.markup?.bounds
    }

    var zoomRangeForTesting: ClosedRange<CGFloat>? {
        paperViewController?.zoomRange
    }

    var contentVisibleFrameForTesting: CGRect? {
        paperViewController?.contentVisibleFrame
    }

    var toolPickerAccessoryItemForTesting: UIBarButtonItem? {
        toolPicker?.accessoryItem
    }

    var supportedFeatureSetForTesting: FeatureSet? {
        paperViewController?.supportedFeatureSet
    }

    var didApplyInitialFitForTesting: Bool { didApplyInitialFit }

    var toolPickerColorUserInterfaceStyleForTesting: UIUserInterfaceStyle? {
        toolPicker?.colorUserInterfaceStyle
    }

    var toolPickerStateAutosaveNameForTesting: String? {
        toolPicker?.stateAutosaveName
    }

    var drawingToolColorForTesting: UIColor? {
        (paperViewController?.drawingTool as? PKInkingTool)?.color
    }

    init(
        background: PaperMarkupCanvasSession.Background,
        onAddToChat: ((PendingAttachment, String) -> Bool)? = nil,
        onCancel: (() -> Void)? = nil,
        destination: ComposerCanvasDestination? = nil,
        onDeliveryAccepted: (() -> Void)? = nil
    ) {
        self.background = background
        self.onCancel = onCancel
        if let destination {
            self.destination = destination
        } else if let onAddToChat {
            self.destination = ComposerCanvasDestination(sessionId: "composer-cover") {
                attachment, recognizedText in
                onAddToChat(attachment, recognizedText)
            }
        } else {
            self.destination = nil
        }
        self.onDeliveryAccepted = onDeliveryAccepted
        self.supportedFeatureSet = PaperMarkupCanvasSession.markupFeatureSet(for: background)
        if case .image(let image) = background {
            copiedBackgroundImage = image
        }
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    static func makeFullScreenController(
        background: PaperMarkupCanvasSession.Background,
        onAddToChat: ((PendingAttachment, String) -> Bool)? = nil,
        onCancel: (() -> Void)? = nil,
        destination: ComposerCanvasDestination? = nil,
        onDeliveryAccepted: (() -> Void)? = nil
    ) -> PaperMarkupCanvasHostController {
        PaperMarkupCanvasHostController(
            background: background,
            onAddToChat: onAddToChat,
            onCancel: onCancel,
            destination: destination,
            onDeliveryAccepted: onDeliveryAccepted
        )
    }

    static func present(
        background: PaperMarkupCanvasSession.Background,
        from presenter: UIViewController,
        onAddToChat: ((PendingAttachment, String) -> Bool)? = nil,
        destination: ComposerCanvasDestination? = nil,
        onDeliveryAccepted: (() -> Void)? = nil
    ) {
        let host = makeFullScreenController(
            background: background,
            onAddToChat: onAddToChat,
            destination: destination,
            onDeliveryAccepted: onDeliveryAccepted
        )
        let themeID = ThemeRuntimeState.currentThemeID()
        let navigation = UINavigationController(rootViewController: host)
        navigation.modalPresentationStyle = .fullScreen
        navigation.overrideUserInterfaceStyle = themeID.preferredColorScheme == .light ? .light : .dark
        navigation.view.backgroundColor = UIColor(themeID.palette.bgDark)
        presenter.present(navigation, animated: true)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let themeID = ThemeRuntimeState.currentThemeID()
        let palette = themeID.palette
        overrideUserInterfaceStyle = themeID.preferredColorScheme == .light ? .light : .dark
        view.backgroundColor = UIColor(palette.bgDark)
        setupNavigation(palette: palette)
        setupPaperView()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if paperViewController == nil {
            setupPaperView()
        }
        updatePaperBottomInset()
        applyInitialFitIfNeeded()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
        paperViewController?.becomeFirstResponder()
        canApplyInitialFit = true
        updatePaperBottomInset()
        view.layoutIfNeeded()
        applyInitialFitIfNeeded(ignorePickerVisibility: true)
        restorePersistedInkingTool()
        if !didApplyInitialFit {
            paperViewController?.view.isHidden = false
        }
    }

    override var canBecomeFirstResponder: Bool { true }

    func markChangedForTesting() {
        isDirty = true
    }

    @discardableResult
    func completeAddToChatForTesting(
        attachment: PendingAttachment,
        recognizedText: String
    ) -> PaperMarkupCanvasSession.AddToChatDeliveryOutcome {
        deliverExportedCanvas(attachment: attachment, recognizedText: recognizedText)
    }

    func debugAddToChatForTesting(failExport: Bool = false) async {
        shouldFailNextExportForTesting = failExport
        await exportAndDeliverToChat()
    }

    func debugAddToChatAndWaitUntilExportHeldForTesting() async {
        shouldHoldNextExportForTesting = true
        await withCheckedContinuation { continuation in
            exportStartedHoldForTesting = continuation
            addToChatTapped()
        }
    }

    func debugCancelForTesting() {
        cancelTapped()
    }

    func debugPresentInsertForTesting() {
        guard let insert = toolPicker?.accessoryItem else { return }
        presentMarkupTools(insert)
    }

    func debugApplyInitialFitForTesting() {
        canApplyInitialFit = true
        updatePaperBottomInset()
        applyInitialFitIfNeeded(ignorePickerVisibility: true)
    }

    func debugSelectInkingColorForTesting(_ color: UIColor) {
        guard let picker = toolPicker else { return }
        let current = picker.selectedTool as? PKInkingTool
        picker.selectedTool = PKInkingTool(
            current?.inkType ?? .pen,
            color: color,
            width: current?.width ?? PKInkingTool.InkType.pen.defaultWidth
        )
    }

    func debugFinishHeldExportForTesting() async {
        resumeHeldExportForTesting()
        await exportTask?.value
    }

    fileprivate func markUserChanged() {
        isDirty = true
    }

    private func applyInitialFitIfNeeded(ignorePickerVisibility: Bool = false) {
        guard canApplyInitialFit,
              !didApplyInitialFit,
              let paper = paperViewController,
              let markup = paper.markup else { return }
        // Wait for the docked tray so the first fit uses the unobscured rect.
        if let picker = toolPicker, !picker.isVisible, !ignorePickerVisibility {
            return
        }
        let unobscured = currentUnobscuredRect()
        guard unobscured.width > 1, unobscured.height > 1,
              markup.bounds.width > 0, markup.bounds.height > 0 else { return }

        paper.zoomRange = PaperMarkupCanvasViewport.zoomRangeAllowingAspectFit(
            markupSize: markup.bounds.size,
            unobscuredSize: unobscured.size
        )
        paper.setContentVisibleFrame(
            PaperMarkupCanvasViewport.contentVisibleFrame(for: markup.bounds),
            animated: false
        )
        didApplyInitialFit = true
        revealPaperIfFitted()
    }

    private func revealPaperIfFitted() {
        guard didApplyInitialFit else { return }
        paperViewController?.view.isHidden = false
    }

    private func currentUnobscuredRect() -> CGRect {
        let viewBounds = view.bounds
        guard viewBounds.width > 0, viewBounds.height > 0 else { return viewBounds }
        let paperBounds = paperViewController?.view.bounds ?? viewBounds
        let obscured = toolPicker?.frameObscured(in: view) ?? .null
        let fromPicker = PaperMarkupCanvasViewport.unobscuredRect(
            in: viewBounds,
            obscuredFrame: obscured
        )
        return CGRect(
            x: viewBounds.minX,
            y: viewBounds.minY,
            width: min(paperBounds.width, fromPicker.width),
            height: min(paperBounds.height, fromPicker.height)
        )
    }

    private func updatePaperBottomInset() {
        guard paperBottomConstraint != nil else { return }
        let obscured = toolPicker?.frameObscured(in: view) ?? .null
        let unobscured = PaperMarkupCanvasViewport.unobscuredRect(
            in: view.bounds,
            obscuredFrame: obscured
        )
        let inset = PaperMarkupCanvasViewport.bottomInset(
            viewBounds: view.bounds,
            unobscuredRect: unobscured
        )
        guard paperBottomConstraint?.constant != -inset else { return }
        paperBottomConstraint?.constant = -inset
    }

    private func setupNavigation(palette: ThemePalette) {
        title = "Canvas"
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "Cancel",
            style: .plain,
            target: self,
            action: #selector(cancelTapped)
        )
        navigationItem.leftBarButtonItem?.accessibilityIdentifier = "composer.canvas.cancel"
        navigationItem.leftBarButtonItem?.tintColor = UIColor(palette.fgDim)

        let addButton = UIBarButtonItem(
            title: "Add to Chat",
            style: .done,
            target: self,
            action: #selector(addToChatTapped)
        )
        addButton.accessibilityIdentifier = "composer.canvas.addToChat"
        addButton.tintColor = UIColor(palette.blue)
        addButton.isEnabled = !isExporting
        navigationItem.rightBarButtonItems = [addButton]
    }

    private func makeInsertButton(palette: ThemePalette) -> UIBarButtonItem {
        let insertButton = UIBarButtonItem(
            image: UIImage(systemName: "plus"),
            style: .plain,
            target: self,
            action: #selector(presentMarkupTools(_:))
        )
        insertButton.accessibilityLabel = "Insert"
        insertButton.tintColor = UIColor(palette.cyan)
        return insertButton
    }

    private func applySelectedDrawingTool() {
        guard !isRestoringInkingTool,
              let paper = paperViewController,
              let picker = toolPicker
        else { return }
        paper.drawingTool = PaperMarkupCanvasSession.drawingTool(from: picker)
    }

    private func persistSelectedInkingTool() {
        guard !isRestoringInkingTool,
              let picker = toolPicker,
              let inking = PaperMarkupCanvasSession.drawingTool(from: picker) as? PKInkingTool
        else { return }
        PaperMarkupCanvasSession.LastInkingTool.save(inking)
    }

    private func restorePersistedInkingTool() {
        guard let picker = toolPicker,
              let tool = PaperMarkupCanvasSession.LastInkingTool.load()
        else { return }
        isRestoringInkingTool = true
        picker.selectedTool = tool
        paperViewController?.drawingTool = tool
        isRestoringInkingTool = false
    }

    private func setupPaperView() {
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0, paperViewController == nil else { return }

        let markupBounds = PaperMarkupCanvasViewport.markupBounds(
            imageSize: copiedBackgroundImage?.size ?? .zero,
            fallbackViewSize: bounds.size
        )

        let markup = PaperMarkup(bounds: markupBounds)
        let paper = PaperMarkupViewController(
            markup: markup,
            supportedFeatureSet: supportedFeatureSet
        )
        let relay = PaperMarkupChangeRelay(owner: self)
        paper.delegate = relay
        markupChangeRelay = relay
        paper.isEditable = true

        if let image = copiedBackgroundImage {
            let imageView = UIImageView(image: image)
            imageView.contentMode = .scaleToFill
            imageView.frame = markupBounds
            paper.contentView = imageView
            backgroundImageView = imageView
        }

        let picker = PKToolPicker()
        picker.addObserver(paper)
        picker.addObserver(self)
        picker.accessoryItem = makeInsertButton(palette: ThemeRuntimeState.currentThemeID().palette)
        // Keep picked ink colors literal. Dark-mode inversion turns white into black.
        picker.colorUserInterfaceStyle = .light
        // Restore after the color style so saved colors stay literal.
        picker.stateAutosaveName = PaperMarkupCanvasSession.toolPickerStateAutosaveName
        paper.pencilKitResponderState.activeToolPicker = picker
        paper.pencilKitResponderState.toolPickerVisibility = .visible
        toolPicker = picker
        paper.view.isHidden = true

        addChild(paper)
        paper.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(paper.view)
        let bottom = paper.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        paperBottomConstraint = bottom
        NSLayoutConstraint.activate([
            paper.view.topAnchor.constraint(equalTo: view.topAnchor),
            paper.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            paper.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottom,
        ])
        paper.didMove(toParent: self)
        paperViewController = paper
        restorePersistedInkingTool()
        canApplyInitialFit = true
        updatePaperBottomInset()
        applyInitialFitIfNeeded(ignorePickerVisibility: true)
        revealPaperIfFitted()
    }

    @objc private func cancelTapped() {
        cancelTrackedExport()
        switch cancelDisposition {
        case .dismiss:
            dismissCanvas()
        case .confirmDiscard:
            let alert = UIAlertController(
                title: PaperMarkupCanvasSession.DiscardPrompt.title,
                message: PaperMarkupCanvasSession.DiscardPrompt.message,
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(
                title: PaperMarkupCanvasSession.DiscardPrompt.keepAction,
                style: .cancel
            ))
            alert.addAction(UIAlertAction(
                title: PaperMarkupCanvasSession.DiscardPrompt.discardAction,
                style: .destructive
            ) { [weak self] _ in
                self?.dismissCanvas()
            })
            present(alert, animated: true)
        }
    }

    @objc private func addToChatTapped() {
        guard !isExporting, !isDismissed else { return }
        exportTask = Task { @MainActor [weak self] in
            await self?.exportAndDeliverToChat()
        }
    }

    private func exportAndDeliverToChat() async {
        guard !isExporting, !isDismissed else { return }
        setExporting(true)
        defer {
            setExporting(false)
            exportTask = nil
        }
        if shouldHoldNextExportForTesting {
            shouldHoldNextExportForTesting = false
            await withCheckedContinuation { continuation in
                exportHoldForTesting = continuation
                exportStartedHoldForTesting?.resume()
                exportStartedHoldForTesting = nil
            }
        }
        guard !Task.isCancelled, !isDismissed else { return }
        guard let export = await exportCanvas() else {
            if !Task.isCancelled, !isDismissed {
                presentAddToChatFailure(PaperMarkupCanvasSession.AddToChatFailure.exportMessage)
            }
            return
        }
        guard !Task.isCancelled, !isDismissed else { return }
        _ = deliverExportedCanvas(
            attachment: export.attachment,
            recognizedText: export.recognizedText
        )
    }

    @discardableResult
    private func deliverExportedCanvas(
        attachment: PendingAttachment,
        recognizedText: String
    ) -> PaperMarkupCanvasSession.AddToChatDeliveryOutcome {
        guard !Task.isCancelled, !isDismissed else { return .rejected }
        let outcome = ComposerCanvasDelivery.deliver(
            attachment: attachment,
            recognizedText: recognizedText,
            to: destination
        )
        switch outcome {
        case .accepted:
            dismissCanvasAfterAcceptedDelivery()
        case .missingDestination:
            presentAddToChatFailure(PaperMarkupCanvasSession.AddToChatFailure.missingDestinationMessage)
        case .rejected:
            presentAddToChatFailure(PaperMarkupCanvasSession.AddToChatFailure.destinationRejectedMessage)
        }
        return outcome
    }

    private func setExporting(_ exporting: Bool) {
        isExporting = exporting
        navigationItem.rightBarButtonItems?.first?.isEnabled = !exporting
        if exporting {
            showProgressOverlay()
        } else {
            hideProgressOverlay()
        }
    }

    private func showProgressOverlay() {
        if progressOverlay == nil {
            let overlay = UIView()
            overlay.translatesAutoresizingMaskIntoConstraints = false
            overlay.backgroundColor = UIColor.black.withAlphaComponent(0.35)
            overlay.accessibilityLabel = PaperMarkupCanvasSession.ExportProgress.title
            overlay.isAccessibilityElement = true

            let spinner = UIActivityIndicatorView(style: .large)
            spinner.translatesAutoresizingMaskIntoConstraints = false
            spinner.startAnimating()

            let label = UILabel()
            label.translatesAutoresizingMaskIntoConstraints = false
            label.text = PaperMarkupCanvasSession.ExportProgress.title
            label.textColor = .white
            label.font = .preferredFont(forTextStyle: .headline)
            label.textAlignment = .center

            overlay.addSubview(spinner)
            overlay.addSubview(label)
            NSLayoutConstraint.activate([
                spinner.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
                spinner.centerYAnchor.constraint(equalTo: overlay.centerYAnchor, constant: -16),
                label.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 12),
                label.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            ])
            progressOverlay = overlay
        }
        guard let progressOverlay, progressOverlay.superview == nil else { return }
        view.addSubview(progressOverlay)
        NSLayoutConstraint.activate([
            progressOverlay.topAnchor.constraint(equalTo: view.topAnchor),
            progressOverlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progressOverlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            progressOverlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func hideProgressOverlay() {
        progressOverlay?.removeFromSuperview()
    }

    private func presentAddToChatFailure(_ message: String) {
        lastFailureMessageForTesting = message
        let alert = UIAlertController(
            title: PaperMarkupCanvasSession.AddToChatFailure.title,
            message: message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(
            title: PaperMarkupCanvasSession.AddToChatFailure.keepAction,
            style: .cancel
        ))
        if presentedViewController == nil {
            present(alert, animated: true)
        }
    }

    @objc private func presentMarkupTools(_ sender: UIBarButtonItem) {
        let editor = MarkupEditViewController(supportedFeatureSet: supportedFeatureSet)
        let insertRelay = PaperMarkupInsertRelay(owner: self)
        markupInsertRelay = insertRelay
        editor.delegate = insertRelay
        editor.modalPresentationStyle = .popover
        editor.preferredContentSize = CGSize(width: 300, height: 260)
        if let popover = editor.popoverPresentationController {
            popover.barButtonItem = sender
            popover.permittedArrowDirections = [.up, .down]
            popover.delegate = self
        }
        present(editor, animated: true)
    }

    private func dismissCanvasAfterAcceptedDelivery() {
        dismissCanvas()
        // Do not reuse onCancel — that path is discard/close, not accepted delivery.
        onDeliveryAccepted?()
    }

    private func dismissCanvas() {
        guard !isDismissed else { return }
        isDismissed = true
        cancelTrackedExport()
        didDismissForTesting = true
        onCancel?()
        if presentingViewController != nil {
            dismiss(animated: true)
        }
    }

    private func cancelTrackedExport() {
        exportTask?.cancel()
        resumeHeldExportForTesting()
    }

    private func resumeHeldExportForTesting() {
        let hold = exportHoldForTesting
        exportHoldForTesting = nil
        hold?.resume()
    }

    private func exportCanvas() async -> (attachment: PendingAttachment, recognizedText: String)? {
        if shouldFailNextExportForTesting {
            shouldFailNextExportForTesting = false
            return nil
        }
        guard let markup = paperViewController?.markup else { return nil }
        let bounds = markup.bounds.width > 0 && markup.bounds.height > 0
            ? markup.bounds
            : view.bounds
        guard let rendered = await renderPNG(markup: markup, bounds: bounds) else {
            return nil
        }
        let attachment = PaperMarkupCanvasSession.makePendingImageAttachment(
            pngData: rendered.data,
            image: rendered.image
        )
        // Image-only: never read PaperKit OCR into the composer.
        return (attachment, "")
    }

    private func renderPNG(
        markup: PaperMarkup,
        bounds: CGRect
    ) async -> (data: Data, image: UIImage)? {
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return nil }
        let imagePixelSize = copiedBackgroundImage.map(PaperMarkupCanvasSession.nativePixelSize(of:))
        let screenScale = view.window?.screen.scale ?? UIScreen.main.scale
        let pixelSize = PaperMarkupCanvasSession.exportPixelSize(
            imagePixelSize: imagePixelSize,
            markupSize: size,
            screenScale: screenScale
        )
        let pixelWidth = max(1, Int(pixelSize.width.rounded()))
        let pixelHeight = max(1, Int(pixelSize.height.rounded()))
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        let drawScaleX = CGFloat(pixelWidth) / size.width
        let drawScaleY = CGFloat(pixelHeight) / size.height
        context.scaleBy(x: drawScaleX, y: drawScaleY)
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)

        if let backgroundImage = copiedBackgroundImage {
            UIGraphicsPushContext(context)
            backgroundImage.draw(in: CGRect(origin: .zero, size: size))
            UIGraphicsPopContext()
        } else {
            context.setFillColor(UIColor.white.cgColor)
            context.fill(CGRect(origin: .zero, size: size))
        }

        await markup.draw(
            in: context,
            frame: CGRect(origin: .zero, size: size),
            options: RenderingOptions(darkUserInterfaceStyle: false)
        )
        guard let cgImage = context.makeImage() else { return nil }
        let image = UIImage(cgImage: cgImage, scale: 1, orientation: .up)
        guard let data = image.pngData() else { return nil }
        return (data, image)
    }
}

struct PaperMarkupCanvasHostView: View {
    let background: PaperMarkupCanvasSession.Background
    let onAddToChat: (PendingAttachment, String) -> Bool
    let onCancel: () -> Void

    var body: some View {
        PaperMarkupCanvasHostRepresentable(
            background: background,
            onAddToChat: onAddToChat,
            onCancel: onCancel
        )
        .ignoresSafeArea()
    }
}

private struct PaperMarkupCanvasHostRepresentable: UIViewControllerRepresentable {
    let background: PaperMarkupCanvasSession.Background
    let onAddToChat: (PendingAttachment, String) -> Bool
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UINavigationController {
        let host = PaperMarkupCanvasHostController(
            background: background,
            onAddToChat: onAddToChat,
            onCancel: onCancel
        )
        let navigation = UINavigationController(rootViewController: host)
        navigation.modalPresentationStyle = .fullScreen
        return navigation
    }

    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {}
}

extension PaperMarkupCanvasHostController {
    fileprivate func insertMarkupContents(_ contents: PaperMarkup) -> PaperMarkup {
        let visible = paperViewController?.contentVisibleFrame
            ?? paperViewController?.markup?.bounds
            ?? .zero
        return PaperMarkupInsertScaling.scaledContents(contents, visibleMarkup: visible)
    }

    fileprivate var markupInsertTarget: PaperMarkupViewController? {
        paperViewController
    }
}

extension PaperMarkupCanvasHostController: UIPopoverPresentationControllerDelegate {
    func adaptivePresentationStyle(
        for controller: UIPresentationController
    ) -> UIModalPresentationStyle {
        .none
    }

    func adaptivePresentationStyle(
        for controller: UIPresentationController,
        traitCollection: UITraitCollection
    ) -> UIModalPresentationStyle {
        .none
    }
}

extension PaperMarkupCanvasHostController: PKToolPickerObserver {
    func toolPickerFramesObscuredDidChange(_ toolPicker: PKToolPicker) {
        canApplyInitialFit = true
        updatePaperBottomInset()
        view.layoutIfNeeded()
        applyInitialFitIfNeeded()
    }

    func toolPickerVisibilityDidChange(_ toolPicker: PKToolPicker) {
        canApplyInitialFit = true
        updatePaperBottomInset()
        view.layoutIfNeeded()
        applyInitialFitIfNeeded()
    }

    func toolPickerSelectedToolDidChange(_ toolPicker: PKToolPicker) {
        applySelectedDrawingTool()
        persistSelectedInkingTool()
    }

    func toolPickerSelectedToolItemDidChange(_ toolPicker: PKToolPicker) {
        applySelectedDrawingTool()
        persistSelectedInkingTool()
    }
}

/// Isolated from the host so PaperKit's nonisolated delegate can hop back to MainActor.
private final class PaperMarkupInsertRelay: NSObject, MarkupEditViewController.Delegate, @unchecked Sendable {
    weak var owner: PaperMarkupCanvasHostController?

    init(owner: PaperMarkupCanvasHostController) {
        self.owner = owner
    }

    func markupEditViewController(
        _ markupEditViewController: MarkupEditViewController,
        insertNewShape type: ShapeConfiguration.Shape
    ) {
        Task { @MainActor [weak self] in
            self?.owner?.markupInsertTarget?.markupEditViewController(
                markupEditViewController,
                insertNewShape: type
            )
            markupEditViewController.dismiss(animated: true)
        }
    }

    func markupEditViewControllerInsertNewTextbox(
        _ markupEditViewController: MarkupEditViewController
    ) {
        Task { @MainActor [weak self] in
            self?.owner?.markupInsertTarget?.markupEditViewControllerInsertNewTextbox(
                markupEditViewController
            )
            markupEditViewController.dismiss(animated: true)
        }
    }

    func markupEditViewController(
        _ markupEditViewController: MarkupEditViewController,
        insertNewLineWithStartMarker lineStartMarker: Bool,
        endMarker lineEndMarker: Bool
    ) {
        Task { @MainActor [weak self] in
            self?.owner?.markupInsertTarget?.markupEditViewController(
                markupEditViewController,
                insertNewLineWithStartMarker: lineStartMarker,
                endMarker: lineEndMarker
            )
            markupEditViewController.dismiss(animated: true)
        }
    }

    func markupEditViewController(
        _ markupEditViewController: MarkupEditViewController,
        insertNewContents toInsert: PaperMarkup
    ) {
        Task { @MainActor [weak self] in
            let scaled = self?.owner?.insertMarkupContents(toInsert) ?? toInsert
            self?.owner?.markupInsertTarget?.markupEditViewController(
                markupEditViewController,
                insertNewContents: scaled
            )
            markupEditViewController.dismiss(animated: true)
        }
    }
}

private final class PaperMarkupChangeRelay: NSObject, PaperMarkupViewController.Delegate, @unchecked Sendable {
    weak var owner: PaperMarkupCanvasHostController?

    init(owner: PaperMarkupCanvasHostController) {
        self.owner = owner
    }

    func paperMarkupViewControllerDidChangeMarkup(_ paperMarkupViewController: PaperMarkupViewController) {
        Task { @MainActor [weak self] in
            self?.owner?.markUserChanged()
        }
    }
}

