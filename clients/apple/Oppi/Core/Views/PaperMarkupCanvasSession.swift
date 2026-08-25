import Foundation
import PaperKit
import UIKit

/// Shared PaperKit markup contract used by the composer and full-screen viewers.
///
/// The host never writes markup back to a source file. Add to Chat always
/// produces a PNG pending image attachment plus any recognized text.
enum PaperMarkupCanvasSession {
    enum Background {
        case blank
        case image(UIImage)
    }

    enum CancelDisposition: Equatable {
        case dismiss
        case confirmDiscard
    }

    enum AnnotateSource: Equatable {
        case currentImage
        case renderedSnapshot
    }

    enum ViewerKind: Equatable {
        case rasterImage
        case svg
        case html
    }

    enum AttachmentMenuItem: String, CaseIterable, Equatable {
        case photoLibrary = "Photo Library"
        case camera = "Camera"
        case chooseFile = "Choose File"
        case canvas = "Canvas"

        var title: String { rawValue }

        var systemImage: String {
            switch self {
            case .photoLibrary:
                return "photo.on.rectangle"
            case .camera:
                return "camera"
            case .chooseFile:
                return "paperclip"
            case .canvas:
                return "pencil.and.scribble"
            }
        }
    }

    enum DiscardPrompt {
        static let title = "Discard Canvas?"
        static let message = "Your drawing will be lost."
        static let discardAction = "Discard"
        static let keepAction = "Keep Editing"
    }

    enum AnnotateAction {
        static let title = "Annotate"
        static let systemImage = "pencil.tip.crop.circle"
        static let imageViewerIdentifier = "fullscreen-image.annotate"
        static let dataViewerIdentifier = "fullscreen-image-data.annotate"
        static let htmlViewerIdentifier = "fullscreen-code.annotate"
    }

    static let attachmentMenuItems: [AttachmentMenuItem] = [
        .photoLibrary, .camera, .chooseFile, .canvas,
    ]

    static let writesBackToSourceFile = false

    enum AddToChatDeliveryOutcome: Equatable {
        case accepted
        case rejected
        case missingDestination
    }

    enum AddToChatFailure {
        static let title = "Couldn't Add to Chat"
        static let missingDestinationMessage =
            "This annotation isn't linked to a chat. Open it from a conversation and try again."
        static let destinationRejectedMessage =
            "Couldn't add this drawing to the chat. Your work is still here."
        static let exportMessage = "Couldn't export this drawing. Your work is still here."
        static let snapshotTitle = "Couldn't Capture View"
        static let snapshotMessage = "Wait for the page to finish rendering and try again."
        static let keepAction = "Keep Editing"
    }

    enum ExportProgress {
        static let title = "Adding to Chat…"
    }

    enum SnapshotError: LocalizedError {
        case notReady
        case failed(Error?)

        var errorDescription: String? {
            switch self {
            case .notReady:
                return AddToChatFailure.snapshotMessage
            case .failed(let error):
                return error?.localizedDescription ?? AddToChatFailure.snapshotMessage
            }
        }
    }

    static func cancelDisposition(isDirty: Bool) -> CancelDisposition {
        isDirty ? .confirmDiscard : .dismiss
    }

    static func annotateSource(for viewer: ViewerKind) -> AnnotateSource {
        switch viewer {
        case .rasterImage:
            return .currentImage
        case .svg, .html:
            return .renderedSnapshot
        }
    }

    static func resolvedRecognizedText(
        indexableContent: String?,
        handwritingFallback: String?
    ) -> String {
        let indexable = indexableContent?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !indexable.isEmpty {
            return indexable
        }
        return handwritingFallback?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static func prependRecognizedText(_ recognized: String, into composerText: String) -> String {
        let trimmed = recognized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return composerText }
        let existing = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !existing.isEmpty else { return trimmed }
        return "\(trimmed)\n\n\(composerText)"
    }

    static func nativePixelSize(of image: UIImage) -> CGSize {
        if let cgImage = image.cgImage {
            return CGSize(width: cgImage.width, height: cgImage.height)
        }
        return CGSize(
            width: image.size.width * image.scale,
            height: image.size.height * image.scale
        )
    }

    static func cappedPixelSize(_ size: CGSize, maxLongEdge: CGFloat = PendingImage.autoResizeMaxDimension) -> CGSize {
        let width = max(1, size.width)
        let height = max(1, size.height)
        let longest = max(width, height)
        guard longest > maxLongEdge else {
            return CGSize(width: width, height: height)
        }
        let scale = maxLongEdge / longest
        return CGSize(width: floor(width * scale), height: floor(height * scale))
    }

    static func copiedImage(from image: UIImage) -> UIImage {
        let pixelSize = cappedPixelSize(nativePixelSize(of: image))
        let size = CGSize(width: max(1, pixelSize.width), height: max(1, pixelSize.height))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    static func exportPixelSize(
        imagePixelSize: CGSize?,
        markupSize: CGSize,
        screenScale: CGFloat
    ) -> CGSize {
        let raw: CGSize
        if let imagePixelSize, imagePixelSize.width > 0, imagePixelSize.height > 0 {
            raw = imagePixelSize
        } else {
            raw = CGSize(
                width: markupSize.width * screenScale,
                height: markupSize.height * screenScale
            )
        }
        return cappedPixelSize(raw)
    }

    static func renderedSnapshot(image: UIImage?, error: Error?) -> Result<UIImage, Error> {
        if let image {
            return .success(image)
        }
        if let error {
            return .failure(error)
        }
        return .failure(SnapshotError.failed(nil))
    }

    static func makePendingImageAttachment(pngData: Data, image: UIImage) -> PendingAttachment {
        PendingImage.from(data: pngData, mimeType: "image/png", image: image).pendingAttachment
    }

    static func applyAddToChat(
        pngData: Data,
        image: UIImage,
        recognizedText: String,
        composerText: inout String,
        pendingAttachments: inout [PendingAttachment]
    ) {
        pendingAttachments.append(makePendingImageAttachment(pngData: pngData, image: image))
        composerText = prependRecognizedText(recognizedText, into: composerText)
    }

    /// Image annotate keeps drawing, text, and shapes. Stickers, links, loupes,
    /// and extra image insertion fight the photo and the PencilKit tray.
    /// Blank composer canvas stays on the broader system set.
    static func markupFeatureSet(for background: Background) -> FeatureSet {
        var features = FeatureSet.latest
        features.remove(.links)
        if case .image = background {
            features.remove(.images)
        }
        return features
    }
}

/// Scales a PaperKit insert (loupe/sticker) from default markup-point size
/// into a usable fraction of the visible page.
///
/// Inserts use markup coordinates. A default ~80pt loupe on a 2000pt photo
/// is a speck. Apple HIG also wants a direct connection with the content.
enum PaperMarkupInsertScaling {
    static let visibleSideFraction: CGFloat = 0.36
    static let minimumScale: CGFloat = 1.25

    static func transform(
        source: CGRect,
        visibleMarkup: CGRect
    ) -> CGAffineTransform? {
        guard source.width > 1, source.height > 1,
              visibleMarkup.width > 1, visibleMarkup.height > 1 else {
            return nil
        }
        let targetSide = min(visibleMarkup.width, visibleMarkup.height) * visibleSideFraction
        let scale = targetSide / max(source.width, source.height)
        guard scale >= minimumScale else { return nil }
        let from = CGPoint(x: source.midX, y: source.midY)
        let to = CGPoint(x: visibleMarkup.midX, y: visibleMarkup.midY)
        return CGAffineTransform(translationX: -from.x, y: -from.y)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: to.x, y: to.y))
    }

    static func scaledContents(
        _ contents: PaperMarkup,
        visibleMarkup: CGRect
    ) -> PaperMarkup {
        var next = contents
        let source = contents.contentsRenderFrame
        guard !source.isNull, !source.isEmpty,
              let transform = transform(source: source, visibleMarkup: visibleMarkup) else {
            return contents
        }
        next.transformContent(transform)
        return next
    }
}

/// PaperKit zoom contract: markup stays in image-model points; the first
/// visible frame is an aspect-fit of that rectangle into the unobscured view.
enum PaperMarkupCanvasViewport {
    static func markupBounds(imageSize: CGSize, fallbackViewSize: CGSize) -> CGRect {
        let size: CGSize
        if imageSize.width > 0, imageSize.height > 0 {
            size = imageSize
        } else {
            size = fallbackViewSize
        }
        return CGRect(origin: .zero, size: size)
    }

    static func unobscuredRect(in viewBounds: CGRect, obscuredFrame: CGRect) -> CGRect {
        guard viewBounds.width > 0, viewBounds.height > 0 else { return viewBounds }
        guard !obscuredFrame.isNull, !obscuredFrame.isInfinite, !obscuredFrame.isEmpty,
              viewBounds.intersects(obscuredFrame) else {
            return viewBounds
        }
        let intersection = viewBounds.intersection(obscuredFrame)
        let docksToBottom = abs(intersection.maxY - viewBounds.maxY) < 0.5
            && intersection.minY > viewBounds.minY
        guard docksToBottom else { return viewBounds }
        return CGRect(
            x: viewBounds.minX,
            y: viewBounds.minY,
            width: viewBounds.width,
            height: max(0, intersection.minY - viewBounds.minY)
        )
    }

    static func aspectFitScale(markupSize: CGSize, unobscuredSize: CGSize) -> CGFloat {
        guard markupSize.width > 0, markupSize.height > 0,
              unobscuredSize.width > 0, unobscuredSize.height > 0 else {
            return 1
        }
        return min(unobscuredSize.width / markupSize.width, unobscuredSize.height / markupSize.height)
    }

    static func zoomRangeAllowingAspectFit(
        markupSize: CGSize,
        unobscuredSize: CGSize,
        maximumZoom: CGFloat = 8
    ) -> ClosedRange<CGFloat> {
        let fit = aspectFitScale(markupSize: markupSize, unobscuredSize: unobscuredSize)
        let minimum = min(fit, 1)
        let maximum = max(maximumZoom, fit, minimum)
        return minimum...maximum
    }

    static func contentVisibleFrame(for markupBounds: CGRect) -> CGRect {
        markupBounds
    }

    static func bottomInset(viewBounds: CGRect, unobscuredRect: CGRect) -> CGFloat {
        max(0, viewBounds.maxY - unobscuredRect.maxY)
    }
}

@MainActor
final class ComposerCanvasDestination {
    let sessionId: String
    private var acceptHandler: (PendingAttachment, String) -> Bool

    init(sessionId: String, accept: @escaping (PendingAttachment, String) -> Bool) {
        self.sessionId = sessionId
        self.acceptHandler = accept
    }

    @discardableResult
    func accept(attachment: PendingAttachment, recognizedText: String) -> Bool {
        acceptHandler(attachment, recognizedText)
    }

    /// SwiftUI chat rebuilds a new destination object each body. Keep one
    /// owner for that session and only refresh the accept handler.
    func adoptAcceptHandler(from other: ComposerCanvasDestination) {
        acceptHandler = other.acceptHandler
    }
}

@MainActor
enum ComposerCanvasDelivery {
    static func deliver(
        attachment: PendingAttachment,
        recognizedText: String,
        to destination: ComposerCanvasDestination?
    ) -> PaperMarkupCanvasSession.AddToChatDeliveryOutcome {
        guard let destination else { return .missingDestination }
        return destination.accept(attachment: attachment, recognizedText: recognizedText)
            ? .accepted
            : .rejected
    }
}

@MainActor
enum ComposerCanvasActiveDestination {
    private static var stack: [ComposerCanvasDestination] = []

    static var current: ComposerCanvasDestination? { stack.last }

    static func push(_ destination: ComposerCanvasDestination) {
        stack.removeAll { $0.sessionId == destination.sessionId }
        stack.append(destination)
    }

    static func pop(_ destination: ComposerCanvasDestination) {
        stack.removeAll { $0 === destination || $0.sessionId == destination.sessionId }
    }

    static func resetForTesting() {
        stack.removeAll()
    }
}

@MainActor
enum ComposerCanvasDestinationResolver {
    static func resolve(from viewController: UIViewController) -> ComposerCanvasDestination? {
        var current: UIViewController? = viewController
        var seen = Set<ObjectIdentifier>()
        while let viewController = current {
            let identity = ObjectIdentifier(viewController)
            guard seen.insert(identity).inserted else { break }
            if let destination = viewController.composerCanvasDestination {
                return destination
            }
            if let presenter = viewController.presentingViewController {
                current = presenter
                continue
            }
            current = viewController.parent
        }
        // Timeline rows present from a cell host that is not on the associated-object
        // chain. The visible chat registers here on appear.
        return ComposerCanvasActiveDestination.current
    }
}

extension UIViewController {
    func presentPaperMarkupSnapshotFailure(_ error: Error) {
        let message: String
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription,
           !description.isEmpty {
            message = description
        } else {
            let description = error.localizedDescription
            message = description.isEmpty
                ? PaperMarkupCanvasSession.AddToChatFailure.snapshotMessage
                : description
        }
        let alert = UIAlertController(
            title: PaperMarkupCanvasSession.AddToChatFailure.snapshotTitle,
            message: message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
        present(alert, animated: true)
    }

    private enum ComposerCanvasDestinationAssociation {
        nonisolated(unsafe) static var key: UInt8 = 0
    }

    var composerCanvasDestination: ComposerCanvasDestination? {
        get {
            objc_getAssociatedObject(self, &ComposerCanvasDestinationAssociation.key) as? ComposerCanvasDestination
        }
        set {
            objc_setAssociatedObject(
                self,
                &ComposerCanvasDestinationAssociation.key,
                newValue,
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
    }
}

final class ComposerCanvasDestinationAnchorController: UIViewController {
    private var storedDestination: ComposerCanvasDestination?

    var destination: ComposerCanvasDestination? {
        get { storedDestination }
        set {
            if let current = storedDestination,
               let next = newValue,
               current.sessionId == next.sessionId {
                current.adoptAcceptHandler(from: next)
                install()
                publishIfVisible()
                return
            }
            if storedDestination !== newValue {
                if let oldValue = storedDestination {
                    ComposerCanvasActiveDestination.pop(oldValue)
                }
                storedDestination = newValue
            }
            install()
            publishIfVisible()
        }
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        install()
        publishIfVisible()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        install()
        publishIfVisible()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if let destination {
            ComposerCanvasActiveDestination.pop(destination)
        }
    }

    private func install() {
        composerCanvasDestination = destination
        parent?.composerCanvasDestination = destination
    }

    private func publishIfVisible() {
        guard viewIfLoaded?.window != nil, let destination else { return }
        ComposerCanvasActiveDestination.push(destination)
    }
}
