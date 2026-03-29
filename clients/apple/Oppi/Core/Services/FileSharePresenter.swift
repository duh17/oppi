import SwiftUI
import UIKit

// MARK: - FileSharePresenter

/// Single entry point for all share/export interactions across SwiftUI and UIKit.
///
/// Owns the full share flow: format selection → render → activity controller.
/// UIKit callers use ``makeShareBarButtonItem(for:tintColor:)`` to get a
/// fully-wired button. SwiftUI callers use ``FileShareButton``.
/// Both delegate to the same render + present logic here.
@MainActor
enum FileSharePresenter {

    // MARK: - Render + Present

    /// Share content using the smart default format.
    static func shareDefault(_ content: FileShareService.ShareableContent) async {
        let format = FileShareService.defaultFormat(for: content)
        await share(content, format: format)
    }

    /// Share content in a specific format.
    static func share(
        _ content: FileShareService.ShareableContent,
        format: FileShareService.ExportFormat
    ) async {
        let item = await FileShareService.render(content, as: format)
        presentActivityController(item: item)
    }

    // MARK: - UIKit Bar Button Factory

    /// Create a fully-wired share bar button item.
    ///
    /// Single-format content (images, PDFs): tap exports directly.
    /// Multi-format content (code, markdown, etc.): tap opens format picker menu.
    ///
    /// Used by ``FullScreenCodeViewController``, ``FullScreenImageViewController``,
    /// and any UIKit surface that needs a share button.
    static func makeShareBarButtonItem(
        for content: FileShareService.ShareableContent,
        tintColor: UIColor? = nil
    ) -> UIBarButtonItem {
        let formats = FileShareService.availableFormats(for: content)
        let shareImage = UIImage(systemName: "square.and.arrow.up")
        let button: UIBarButtonItem

        if formats.count <= 1 {
            // Single format — tap exports directly
            button = UIBarButtonItem(
                image: shareImage,
                primaryAction: UIAction { _ in
                    Task { @MainActor in
                        await shareDefault(content)
                    }
                }
            )
        } else {
            // Multiple formats — tap opens format picker menu
            button = UIBarButtonItem(
                image: shareImage,
                menu: buildFormatMenu(for: content)
            )
        }

        button.tintColor = tintColor
        return button
    }

    // MARK: - Format Menu

    /// Build a UIMenu with format options for the given content.
    ///
    /// Each menu item renders the content in that format and presents
    /// the system share sheet. Shared between bar button items and
    /// any other UIKit surface that needs a format picker.
    static func buildFormatMenu(
        for content: FileShareService.ShareableContent
    ) -> UIMenu {
        let formats = FileShareService.availableFormats(for: content)
        let actions = formats.map { format in
            let info = FileShareService.formatDisplayInfo(format, for: content)
            return UIAction(
                title: info.label,
                image: UIImage(systemName: info.icon)
            ) { _ in
                Task { @MainActor in
                    await share(content, format: format)
                }
            }
        }
        return UIMenu(children: actions)
    }

    // MARK: - Activity Controller Presentation

    /// Present UIActivityViewController from the topmost view controller.
    ///
    /// Handles popover positioning for iPad. Cleans up temp files on completion.
    static func presentActivityController(item: FileShareService.ShareItem) {
        guard let topVC = topViewController() else { return }

        let ac = UIActivityViewController(
            activityItems: item.activityItems,
            applicationActivities: nil
        )
        ac.completionWithItemsHandler = { _, _, _, _ in
            FileShareService.cleanupTempFiles()
        }
        if let popover = ac.popoverPresentationController {
            popover.sourceView = topVC.view
            popover.sourceRect = CGRect(
                x: topVC.view.bounds.midX,
                y: 44,
                width: 0,
                height: 0
            )
        }
        topVC.present(ac, animated: true)
    }

    private static func topViewController() -> UIViewController? {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
              let rootVC = scene.keyWindow?.rootViewController else {
            return nil
        }

        var topVC = rootVC
        while let presented = topVC.presentedViewController {
            topVC = presented
        }
        return topVC
    }
}

// MARK: - FileShareButton

/// Reusable share button for SwiftUI surfaces.
///
/// Single-format content: tap exports directly (no picker needed).
/// Multi-format content: tap opens format picker menu.
/// Delegates all logic to ``FileSharePresenter``.
struct FileShareButton: View {
    let content: FileShareService.ShareableContent
    let style: ButtonStyle

    enum ButtonStyle {
        /// Floating capsule with material background (for overlays).
        case capsule
        /// Plain icon button (for toolbars, headers).
        case icon
    }

    @State private var isExporting = false

    init(content: FileShareService.ShareableContent, style: ButtonStyle = .capsule) {
        self.content = content
        self.style = style
    }

    var body: some View {
        let formats = FileShareService.availableFormats(for: content)

        if formats.count <= 1 {
            Button {
                Task { await exportDefault() }
            } label: {
                shareLabel
            }
            .disabled(isExporting)
        } else {
            Menu {
                ForEach(formats, id: \.self) { format in
                    Button {
                        Task { await export(format: format) }
                    } label: {
                        let info = FileShareService.formatDisplayInfo(format, for: content)
                        Label(info.label, systemImage: info.icon)
                    }
                }
            } label: {
                shareLabel
            }
            .disabled(isExporting)
        }
    }

    @ViewBuilder
    private var shareLabel: some View {
        Group {
            switch style {
            case .capsule:
                Label("Share", systemImage: "square.and.arrow.up")
                    .font(.caption2.bold())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
            case .icon:
                Image(systemName: "square.and.arrow.up")
                    .font(.caption2)
            }
        }
        .opacity(isExporting ? 0.5 : 1)
    }

    private func exportDefault() async {
        guard !isExporting else { return }
        isExporting = true
        defer { isExporting = false }
        await FileSharePresenter.shareDefault(content)
    }

    private func export(format: FileShareService.ExportFormat) async {
        guard !isExporting else { return }
        isExporting = true
        defer { isExporting = false }
        await FileSharePresenter.share(content, format: format)
    }
}
