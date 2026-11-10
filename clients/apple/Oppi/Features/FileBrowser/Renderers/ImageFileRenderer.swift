import UIKit

/// An image file, decoded on the page and opened full screen on tap.
final class ImageFileRenderer: FileRenderer {
    private let data: Data
    private let file: FileRenderInput

    private init(data: Data, file: FileRenderInput) {
        self.data = data
        self.file = file
    }

    static func load(_ file: FileRenderInput) async throws -> ImageFileRenderer? {
        guard let read = try await file.bytes() else { return nil }
        return ImageFileRenderer(data: read.data, file: file)
    }

    func mount(in host: FileRendererHost) -> UIView {
        let page = UIView()
        host.addPage(page)
        let scroll = UIScrollView()
        scroll.alwaysBounceVertical = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(scroll)
        let safe = page.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: safe.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: safe.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
        ])
        let image = DataImagePreviewView(
            data: data,
            mimeType: MediaMimeType.imageMimeType(forPathExtension: file.fileExtension),
            maxPixelSize: 2_400
        )
        image.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(image)
        let inset: CGFloat = 16
        NSLayoutConstraint.activate([
            image.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: inset),
            image.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -inset),
            image.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: inset),
            image.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -inset),
        ])
        return page
    }

    func makeShareItem(host: FileRendererHost) -> UIBarButtonItem? {
        FileShareService.ShareableContent.imageData(data, filename: file.fileName).shareBarItem
    }
}
