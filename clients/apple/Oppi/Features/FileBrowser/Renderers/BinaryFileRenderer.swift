import QuickLook
import UIKit
import UniformTypeIdentifiers

/// A file no other renderer draws, as a card: its type, size, and when it
/// changed, with Share, Save to Files, and Quick Look where the system can
/// preview its type. Nothing is read until an action asks: the action
/// downloads the file to disk once (`FileSharePresenter.download`, with
/// progress and Cancel) and the card keeps that copy until it goes away.
///
/// The viewer also shows text too large to read whole this way, with a
/// notice that says so (`FileRenderInput.notice`).
final class BinaryFileRenderer: FileRenderer {
    private let file: FileRenderInput
    private let facts: FileCardFacts
    /// This card's own folder for its download: Share's temporary files are
    /// removed whenever any share sheet closes, so the card keeps its copy apart.
    private let downloadFolder = FileManager.default.temporaryDirectory
        .appendingPathComponent("FileCards", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    private var localCopy: URL?
    private weak var host: FileRendererHost?
    private weak var card: FileCardView?
    private var previewSource: FileCardPreviewSource?

    private init(file: FileRenderInput, facts: FileCardFacts) {
        self.file = file
        self.facts = facts
    }

    isolated deinit {
        try? FileManager.default.removeItem(at: downloadFolder)
    }

    /// Reads what a HEAD says about the file; no bytes. A file the server
    /// says is gone or refused throws; any other HEAD failure (an older
    /// server's size cap, a route without HEAD) leaves its size and date unknown.
    static func load(_ file: FileRenderInput) async throws -> BinaryFileRenderer? {
        var head: RemoteFileHead?
        do {
            head = try await file.head()
        } catch FileDownloadError.rejected(let status, _) where [401, 403, 404].contains(status) {
            throw APIError.server(status: status, message: HTTPURLResponse.localizedString(forStatusCode: status))
        } catch {
            head = nil
        }
        guard file.isCurrent() else { return nil }
        let byteCount = file.preread.map { Int64($0.count) }
            ?? head?.byteCount
            ?? file.listedSize.map(Int64.init)
        return BinaryFileRenderer(file: file, facts: FileCardFacts(
            fileName: file.fileName,
            byteCount: byteCount,
            modifiedAt: head?.modifiedAt,
            notice: file.notice
        ))
    }

    var retention: FileRendererRetention { .keepOnReshow }

    func mount(in host: FileRendererHost) -> UIView {
        self.host = host
        let card = FileCardView(
            facts: facts,
            palette: ThemeRuntimeState.currentPalette(),
            actions: FileCardView.Actions(
                quickLook: { [weak self] in self?.run(.quickLook, from: $0) },
                share: { [weak self] in self?.run(.share, from: $0) },
                save: { [weak self] in self?.run(.save, from: $0) }
            )
        )
        card.setCanQuickLook(canQuickLook)
        self.card = card
        host.addPage(card)
        return card
    }

    func updateMounted(palette: ThemePalette) {
        card?.apply(palette)
    }

    func release() {
        try? FileManager.default.removeItem(at: downloadFolder)
        localCopy = nil
    }

    /// The bar's Share: this card's copy when it has one, else a download of its own.
    var share: ShareableFile {
        let remote = remoteFile
        return .remote(RemoteFileShare(fileName: remote.fileName, expectedBytes: remote.expectedBytes) { [weak self] destination, onProgress in
            if let local = self?.existingLocalCopy {
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try FileManager.default.copyItem(at: local, to: destination)
            } else {
                try await remote.download(destination, onProgress)
            }
        })
    }

    // MARK: Actions

    private enum Action { case quickLook, share, save }

    private func run(_ action: Action, from button: UIView) {
        guard let host else { return }
        Task { @MainActor [weak self] in
            guard let self, let url = await localFile(from: host) else { return }
            card?.setCanQuickLook(canQuickLook)
            switch action {
            case .quickLook:
                let source = FileCardPreviewSource(url: url)
                previewSource = source
                let preview = QLPreviewController()
                preview.dataSource = source
                Router.topPresenter(from: host).present(preview, animated: true)
            case .share:
                FileSharePresenter.presentActivityController(item: .file(url), from: host, sourceItem: button)
            case .save:
                let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
                Router.topPresenter(from: host).present(picker, animated: true)
            }
        }
    }

    private var remoteFile: RemoteFileShare {
        file.access.remoteFileShare(
            api: file.api,
            path: file.path,
            fileName: file.fileName,
            size: facts.byteCount.map { Int(clamping: $0) }
        )
    }

    private var existingLocalCopy: URL? {
        guard let localCopy, FileManager.default.fileExists(atPath: localCopy.path) else { return nil }
        return localCopy
    }

    /// The file on this device: the copy this card already has, the bytes
    /// the viewer read, or a download now. Nil when the download failed or
    /// was cancelled (`FileSharePresenter.download` said why).
    private func localFile(from screen: UIViewController) async -> URL? {
        if let existingLocalCopy { return existingLocalCopy }
        let destination = downloadFolder.appendingPathComponent(
            FileShareService.fileName(fromPath: file.fileName) ?? "file"
        )
        if let preread = file.preread {
            do {
                try FileManager.default.createDirectory(at: downloadFolder, withIntermediateDirectories: true)
                try preread.write(to: destination)
            } catch {
                return nil
            }
        } else {
            guard await FileSharePresenter.download(remoteFile, to: destination, from: screen) else { return nil }
        }
        localCopy = destination
        return destination
    }

    /// Whether Quick Look previews this type: asked of the downloaded copy
    /// once there is one, else of the file's name.
    private var canQuickLook: Bool {
        let url = existingLocalCopy ?? downloadFolder.appendingPathComponent(
            FileShareService.fileName(fromPath: file.fileName) ?? "file"
        )
        return PlatformCapabilities.quickLookPreviews(url)
    }
}

/// What the file card shows before anything downloads.
struct FileCardFacts: Equatable {
    let fileName: String
    let byteCount: Int64?
    let modifiedAt: Date?
    var notice: String? = nil

    /// The system's type for the name's extension, else plain data.
    var contentType: UTType {
        let ext = (fileName as NSString).pathExtension
        return ext.isEmpty ? .data : UTType(filenameExtension: ext) ?? .data
    }

    /// "ZIP archive · 24.3 MB": the system's name for the type and the size.
    var summary: String {
        let kind = Self.kindName(for: contentType, fileName: fileName)
        guard let byteCount else { return kind }
        let size = ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
        return String(localized: "\(kind) · \(size)")
    }

    var modifiedText: String? {
        modifiedAt.map { String(localized: "Modified \($0.formatted(date: .abbreviated, time: .shortened))") }
    }

    /// The symbol of the widest family the type belongs to.
    var systemImage: String {
        let families: [(UTType, String)] = [
            (.archive, "doc.zipper"),
            (.diskImage, "externaldrive"),
            (.spreadsheet, "tablecells"),
            (.presentation, "rectangle.on.rectangle.angled"),
            (.database, "cylinder.split.1x2"),
            (.font, "textformat"),
            (.executable, "terminal"),
            (.image, "photo"),
            (.audio, "waveform"),
            (.movie, "film"),
            (.pdf, "doc.richtext"),
            (.text, "doc.text"),
        ]
        let type = contentType
        return families.first { type.conforms(to: $0.0) }?.1 ?? "doc"
    }

    private static func kindName(for type: UTType, fileName: String) -> String {
        if type.isDeclared, let name = type.localizedDescription { return name }
        let ext = (fileName as NSString).pathExtension
        return ext.isEmpty ? String(localized: "File") : String(localized: "\(ext.uppercased()) File")
    }
}

/// The one item Quick Look shows: the card's downloaded copy.
private final class FileCardPreviewSource: NSObject, QLPreviewControllerDataSource {
    let url: URL

    init(url: URL) {
        self.url = url
    }

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem {
        url as NSURL
    }
}

/// The file card's page: the facts, centered, and the actions under them.
final class FileCardView: UIView {
    struct Actions {
        let quickLook: (UIView) -> Void
        let share: (UIView) -> Void
        let save: (UIView) -> Void
    }

    private let icon = UIImageView()
    private let name = UILabel()
    private let summary = UILabel()
    private let modified = UILabel()
    private let notice = UILabel()
    private let quickLookButton: UIButton
    private let shareButton: UIButton
    private let saveButton: UIButton

    init(facts: FileCardFacts, palette: ThemePalette, actions: Actions) {
        quickLookButton = Self.button(
            String(localized: "Quick Look"), systemImage: "eye", id: "fileViewer.card.quickLook", action: actions.quickLook
        )
        shareButton = Self.button(
            FileSharePresenter.shareTitle, systemImage: "square.and.arrow.up", id: "fileViewer.card.share", action: actions.share
        )
        saveButton = Self.button(
            String(localized: "Save to Files"), systemImage: "folder", id: "fileViewer.card.save", action: actions.save
        )
        super.init(frame: .zero)
        accessibilityIdentifier = "fileViewer.card"

        icon.image = UIImage(systemName: facts.systemImage)
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 56, weight: .light)
        icon.contentMode = .scaleAspectFit
        icon.isAccessibilityElement = false

        name.text = facts.fileName
        name.font = .preferredFont(forTextStyle: .headline)
        name.numberOfLines = 0
        name.lineBreakMode = .byCharWrapping
        name.accessibilityIdentifier = "fileViewer.card.name"

        summary.text = facts.summary
        summary.font = UIFont.scaled(.subheadline, monospacedDigits: true)
        summary.accessibilityIdentifier = "fileViewer.card.summary"

        modified.text = facts.modifiedText
        modified.font = .preferredFont(forTextStyle: .footnote)
        modified.isHidden = facts.modifiedText == nil

        notice.text = facts.notice
        notice.font = .preferredFont(forTextStyle: .callout)
        notice.numberOfLines = 0
        notice.isHidden = facts.notice == nil

        for label in [name, summary, modified, notice] {
            label.textAlignment = .center
            label.adjustsFontForContentSizeCategory = true
        }

        let buttons = UIStackView(arrangedSubviews: [quickLookButton, shareButton, saveButton])
        buttons.axis = .vertical
        buttons.spacing = 10
        buttons.alignment = .fill

        let details = UIStackView(arrangedSubviews: [name, summary, modified, notice])
        details.axis = .vertical
        details.alignment = .center
        details.spacing = 6
        details.setCustomSpacing(12, after: modified)

        let stack = UIStackView(arrangedSubviews: [icon, details, buttons])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 16
        stack.setCustomSpacing(28, after: details)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: safeAreaLayoutGuide.centerYAnchor),
            stack.centerXAnchor.constraint(equalTo: safeAreaLayoutGuide.centerXAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: safeAreaLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: safeAreaLayoutGuide.trailingAnchor, constant: -24),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            buttons.widthAnchor.constraint(equalToConstant: 240),
        ])
        apply(palette)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Quick Look leads when the system previews the type; otherwise Share does.
    func setCanQuickLook(_ canQuickLook: Bool) {
        quickLookButton.isHidden = !canQuickLook
        let prominent = canQuickLook ? quickLookButton : shareButton
        for button in [quickLookButton, shareButton, saveButton] {
            let style: UIButton.Configuration = button === prominent ? .borderedProminent() : .bordered()
            var configuration = style
            configuration.title = button.configuration?.title
            configuration.image = button.configuration?.image
            configuration.imagePadding = 8
            configuration.buttonSize = .large
            button.configuration = configuration
        }
    }

    /// Colors from `palette`; the viewer calls this again when the theme changes.
    func apply(_ palette: ThemePalette) {
        icon.tintColor = palette.ui.comment
        name.textColor = palette.ui.fg
        summary.textColor = palette.ui.comment
        modified.textColor = palette.ui.comment
        notice.textColor = palette.ui.yellow
        for button in [quickLookButton, shareButton, saveButton] {
            button.tintColor = palette.ui.syntaxKeyword
        }
    }

    private static func button(
        _ title: String,
        systemImage: String,
        id: String,
        action: @escaping (UIView) -> Void
    ) -> UIButton {
        var configuration = UIButton.Configuration.bordered()
        configuration.title = title
        configuration.image = UIImage(systemName: systemImage)
        configuration.imagePadding = 8
        configuration.buttonSize = .large
        let button = UIButton(configuration: configuration)
        button.addAction(UIAction { [weak button] _ in
            guard let button else { return }
            action(button)
        }, for: .primaryActionTriggered)
        button.accessibilityIdentifier = id
        return button
    }
}
