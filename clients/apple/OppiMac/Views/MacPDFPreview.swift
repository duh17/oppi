import AppKit
import PDFKit
import SwiftUI

/// Decode PDF bytes carried in a file descriptor. Platforms paint; core only stores payload.
enum MacPDFPreviewData {
    static func data(from file: ToolContentDescriptor.File) -> Data? {
        data(from: file.text)
    }

    static func data(from text: String) -> Data? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let data = pdfData(fromBase64: trimmed) {
            return data
        }
        if let marker = trimmed.range(of: "base64,") {
            let payload = String(trimmed[marker.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let data = pdfData(fromBase64: payload) {
                return data
            }
        }
        if trimmed.hasPrefix("%PDF-") {
            return Data(trimmed.utf8)
        }
        return nil
    }

    static func isPDFHeader(_ data: Data) -> Bool {
        data.starts(with: Data("%PDF-".utf8))
    }

    private static func pdfData(fromBase64 text: String) -> Data? {
        guard let data = Data(base64Encoded: text), isPDFHeader(data) else {
            return nil
        }
        return data
    }
}

/// PDFKit preview for FileViewerPlan PDF and tool `read` of a `.pdf`.
struct MacToolDocumentPDFView: View {
    let file: ToolContentDescriptor.File
    var workspaceID: String? = nil
    var sessionID: String? = nil
    var worktreeId: String? = nil

    @State private var document: PDFDocument?
    @State private var didFail = false

    var body: some View {
        Group {
            if let document {
                MacPDFKitView(document: document)
                    .accessibilityIdentifier("mac.documentColumn.pdf")
            } else if didFail {
                ContentUnavailableView(
                    "Unable to Display PDF",
                    systemImage: "doc.questionmark",
                    description: Text("The PDF data could not be decoded.")
                )
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: loadIdentity) {
            await load()
        }
    }

    private var loadIdentity: String {
        "\(file.filePath ?? "")|\(file.text.count)|\(workspaceID ?? "")|\(sessionID ?? "")|\(worktreeId ?? "")"
    }

    private func load() async {
        let requestedIdentity = loadIdentity
        didFail = false
        document = nil
        if let inline = MacPDFPreviewData.data(from: file) {
            if let document = PDFDocument(data: inline) {
                self.document = document
            } else {
                didFail = true
            }
            return
        }
        guard let path = file.filePath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty,
              let workspaceID,
              !workspaceID.isEmpty else {
            didFail = true
            return
        }
        let data = await MacMarkdownWorkspaceFileLoader.data(
            path: path,
            workspaceID: workspaceID,
            sessionID: sessionID,
            worktreeId: worktreeId
        )
        guard !Task.isCancelled, loadIdentity == requestedIdentity else { return }
        guard let data, let document = PDFDocument(data: data) else {
            didFail = true
            return
        }
        self.document = document
    }
}

/// AppKit adapter: PDFKit `PDFView` in the wide document column.
struct MacPDFKitView: NSViewRepresentable {
    let document: PDFDocument

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .clear
        view.document = document
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== document {
            view.document = document
        }
    }
}
