import PDFKit
import UIKit

/// A PDF in a vertical, continuous `PDFView`.
final class PDFFileRenderer: FileRenderer {
    private let data: Data
    private let file: FileRenderInput
    /// The host path the server resolved the file to, when it reported one.
    private let resolvedHostPath: String?

    private init(data: Data, file: FileRenderInput, resolvedHostPath: String?) {
        self.data = data
        self.file = file
        self.resolvedHostPath = resolvedHostPath
    }

    static func load(_ file: FileRenderInput) async throws -> PDFFileRenderer? {
        guard let read = try await file.bytes() else { return nil }
        return PDFFileRenderer(data: read.data, file: file, resolvedHostPath: read.resolvedHostPath)
    }

    /// The page installs its own back swipe on the PDF view.
    var ownsBackSwipe: Bool { true }

    func mount(in host: FileRendererHost) -> UIView {
        guard let document = PDFDocument(data: data) else {
            let invalid = host.unavailable(.empty(
                title: String(localized: "Invalid PDF"),
                systemImage: "doc.badge.exclamationmark",
                message: String(localized: "Could not decode PDF data.")
            ))
            host.installOwnBackSwipe(on: invalid)
            return invalid
        }
        let pdf = ReviewCommentPDFView()
        pdf.autoScales = true
        pdf.displayMode = .singlePageContinuous
        pdf.displayDirection = .vertical
        pdf.backgroundColor = .clear
        pdf.document = document
        pdf.accessibilityIdentifier = "fileViewer.pdf"
        if let selection = host.readerSelectionContext {
            pdf.reviewCommentRouter = selection.dispatcher
            pdf.reviewCommentSourceContext = selection.sourceContextIgnoringSurfaceOverride(
                surface: .fullScreenSource,
                filePath: resolvedHostPath ?? file.path
            )
        }
        let page = UIView()
        host.addPage(page)
        pdf.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(pdf)
        let safe = page.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            pdf.topAnchor.constraint(equalTo: safe.topAnchor),
            pdf.bottomAnchor.constraint(equalTo: page.bottomAnchor),
            pdf.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            pdf.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
        ])
        host.installOwnBackSwipe(on: pdf)
        return page
    }

    var share: ShareableFile { .loaded(.pdfData(data, filename: file.fileName)) }
}

/// A `PDFView` whose text selection edit menu carries the shared Comment (and
/// dictate) actions, as `ReviewCommentWKWebView` does for HTML. The comment
/// anchors to the file, the pages the selection spans, and its text. A page
/// without a text layer (a scan) has no selection, so it offers no Comment.
final class ReviewCommentPDFView: PDFView {
    var reviewCommentRouter: ReviewCommentSelectionRouter?
    var reviewCommentSourceContext: ReviewCommentSourceContext?

    override func buildMenu(with builder: any UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard let reviewCommentRouter,
              reviewCommentSourceContext != nil,
              selectedCommentText != nil else { return }
        let actions = ReviewCommentSelectionMenuBuilder.commentActions(router: reviewCommentRouter) { [weak self] startsDictation in
            self?.handleCommentAction(startsDictation: startsDictation)
        }
        builder.insertSibling(
            UIMenu(title: "", options: .displayInline, children: actions),
            beforeMenu: .standardEdit
        )
    }

    private var selectedCommentText: String? {
        let text = ReviewCommentSelectionTextFormatter.normalizedSelectedText(currentSelection?.string ?? "")
        return text.isEmpty ? nil : text
    }

    private func handleCommentAction(startsDictation: Bool) {
        guard let selection = currentSelection,
              let text = selectedCommentText,
              let router = reviewCommentRouter,
              let source = reviewCommentSourceContext else { return }
        let pageIndices = selection.pages.compactMap { page -> Int? in
            guard let index = document?.index(for: page), index != NSNotFound else { return nil }
            return index
        }
        let pageRange = pageIndices.min().flatMap { first in
            pageIndices.max().map { last in (first + 1)...(last + 1) }
        }
        let request = ReviewCommentSelectionRequest(
            selectedText: text,
            source: source,
            pageRange: pageRange,
            startsDictation: startsDictation
        )
        FeatureEducationTips.markReviewCommentCreated()
        guard router.supportsInlineCommentComposer else {
            router.dispatch(request, presentingViewController: nearestViewController)
            return
        }
        let anchorRect = selection.pages.first.map { page in
            convert(selection.bounds(for: page), from: page)
        }
        clearSelection()
        ReviewCommentInlineDraftPresenter.present(
            sourceView: self,
            anchorRect: anchorRect,
            request: request,
            router: router
        )
    }
}
