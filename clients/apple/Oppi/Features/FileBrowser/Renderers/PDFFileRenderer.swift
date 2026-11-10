import PDFKit
import UIKit

/// A PDF in a vertical, continuous `PDFView`.
final class PDFFileRenderer: FileRenderer {
    private let data: Data
    private let fileName: String

    private init(data: Data, fileName: String) {
        self.data = data
        self.fileName = fileName
    }

    static func load(_ file: FileRenderInput) async throws -> PDFFileRenderer? {
        guard let read = try await file.bytes() else { return nil }
        return PDFFileRenderer(data: read.data, fileName: file.fileName)
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
        let pdf = PDFView()
        pdf.autoScales = true
        pdf.displayMode = .singlePageContinuous
        pdf.displayDirection = .vertical
        pdf.backgroundColor = .clear
        pdf.document = document
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

    func makeShareItem(host: FileRendererHost) -> UIBarButtonItem? {
        FileShareService.ShareableContent.pdfData(data, filename: fileName).shareBarItem
    }
}
