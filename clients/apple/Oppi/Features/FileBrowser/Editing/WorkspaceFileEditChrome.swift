import SwiftUI
import UIKit

/// Spoken save-state words and toolbar glyphs for the editor.
enum WorkspaceFileEditStatusPresentation {
    /// Shape-only mapping. Warning is the triangle, not a tint.
    enum Indicator: Equatable, Sendable {
        case symbol(String)
        case progress
    }

    static func label(for status: WorkspaceFileEditSession.Status) -> String {
        switch status {
        case .saved: String(localized: "Saved")
        case .pending: String(localized: "Edited")
        case .saving: String(localized: "Saving…")
        case .offline: String(localized: "Offline")
        case .verifying: String(localized: "Checking…")
        case .conflict: String(localized: "Conflict")
        case .deleted: String(localized: "Deleted")
        case .tooLarge: String(localized: "Too Large")
        case .failed: String(localized: "Not Saved")
        }
    }

    static func indicator(for status: WorkspaceFileEditSession.Status) -> Indicator {
        switch status {
        case .saved: .symbol("checkmark.circle")
        case .pending: .symbol("pencil.circle")
        case .saving, .verifying: .progress
        case .offline: .symbol("wifi.slash")
        case .conflict, .deleted, .tooLarge, .failed: .symbol("exclamationmark.triangle")
        }
    }

    /// Banner lines. "Kept on this device" is claimed only while the last
    /// protected-draft write succeeded.
    static func bannerLines(
        status: WorkspaceFileEditSession.Status,
        maxBytes: Int,
        draftPersistenceError: String?,
        draftNotice: String?,
        recovered: Bool
    ) -> [String] {
        let kept = draftPersistenceError == nil
            ? " " + String(localized: "Your edits are kept on this device.")
            : ""
        var lines: [String] = []
        switch status {
        case .conflict:
            lines.append(String(localized: "This file changed on the server. Autosave is paused.") + kept)
        case .deleted:
            lines.append(String(localized: "This file is gone from the server and will not be recreated.") + kept)
        case .tooLarge:
            lines.append(String(localized: "Too large to save. The limit is \(SessionFormatting.byteCount(maxBytes)).") + kept)
        case .failed(let message):
            lines.append(String(localized: "Not saved: \(message)") + kept)
        case .offline:
            lines.append(String(localized: "Can't reach the server. Saving will retry.") + kept)
        case .pending where recovered && draftPersistenceError == nil:
            lines.append(String(localized: "Recovered unsaved edits."))
        case .saved, .pending, .saving, .verifying:
            break
        }
        if let draftPersistenceError {
            lines.append(String(
                localized: "Your edits could not be stored on this device (\(draftPersistenceError)). They exist only in this editor until the server saves them."
            ))
        }
        if let draftNotice { lines.append(draftNotice) }
        return lines
    }

    static func offersConflictActions(_ status: WorkspaceFileEditSession.Status) -> Bool {
        switch status {
        case .conflict, .deleted, .failed: true
        default: false
        }
    }
}

/// Passive toolbar glyph. VoiceOver still speaks `label(for:)`.
struct WorkspaceFileEditStatusIndicator: View {
    let status: WorkspaceFileEditSession.Status

    var body: some View {
        glyph
            .frame(width: Self.slot, height: Self.slot, alignment: .center)
    }

    @ViewBuilder
    private var glyph: some View {
        let label = WorkspaceFileEditStatusPresentation.label(for: status)
        switch WorkspaceFileEditStatusPresentation.indicator(for: status) {
        case .progress:
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.small)
                .labelsHidden()
                .tint(.themeComment)
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("workspace-file-editor.status")
                .accessibilityLabel(label)
        case .symbol(let name):
            WorkspaceFileEditStatusSymbolImage(systemName: name, label: label)
        }
    }

    /// Keeps Saving/Checking from resizing Preview and Done.
    private static let slot: CGFloat = 22
}

/// Draws the locked SF Symbol as pixels. A live `Image(systemName:)` or
/// `UIImageView` inside ToolbarItem keeps checkmark.circle's Select trait.
private struct WorkspaceFileEditStatusSymbolImage: UIViewRepresentable {
    let systemName: String
    let label: String

    func makeUIView(context: Context) -> WorkspaceFileEditStatusSymbolCanvas {
        WorkspaceFileEditStatusSymbolCanvas()
    }

    func updateUIView(_ view: WorkspaceFileEditStatusSymbolCanvas, context: Context) {
        view.systemName = systemName
        view.accessibilityLabel = label
    }
}

private final class WorkspaceFileEditStatusSymbolCanvas: UIView {
    var systemName = "" {
        didSet {
            if oldValue != systemName { redrawSymbol() }
        }
    }

    private var symbolImage: UIImage?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityIdentifier = "workspace-file-editor.status"
        accessibilityTraits = []
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(themeDidChange),
            name: .oppiThemeDidChange,
            object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override var intrinsicContentSize: CGSize { CGSize(width: 22, height: 22) }

    override func draw(_ rect: CGRect) {
        symbolImage?.draw(in: rect)
    }

    /// `Color.themeComment` is a snapshot. UIKit toolbar glyphs are not
    /// recreated when the palette changes, so redraw from the live palette.
    @objc private func themeDidChange() {
        redrawSymbol()
    }

    private func redrawSymbol() {
        symbolImage = Self.drawnSymbol(systemName)
        setNeedsDisplay()
    }

    private static func drawnSymbol(_ name: String) -> UIImage? {
        guard !name.isEmpty else { return nil }
        let config = UIImage.SymbolConfiguration(pointSize: 17, weight: .regular)
        guard let symbol = UIImage(systemName: name, withConfiguration: config) else { return nil }
        let tinted = symbol.withTintColor(UIColor(Color.themeComment), renderingMode: .alwaysOriginal)
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        return UIGraphicsImageRenderer(size: tinted.size, format: format).image { _ in
            tinted.draw(at: .zero)
        }
    }
}

struct WorkspaceFileEditBanner: View {
    let session: WorkspaceFileEditSession
    let onReview: () -> Void
    let onUseDisk: () -> Void

    var body: some View {
        let lines = WorkspaceFileEditStatusPresentation.bannerLines(
            status: session.status,
            maxBytes: session.maxBytes,
            draftPersistenceError: session.draftPersistenceError,
            draftNotice: session.draftNotice,
            recovered: session.recoveredDraft
        )
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(lines.joined(separator: "\n"))
                    .font(.footnote)
                    .foregroundStyle(.themeFg)
                    .accessibilityIdentifier("workspace-file-editor.banner")
                if WorkspaceFileEditStatusPresentation.offersConflictActions(session.status) {
                    HStack(spacing: 12) {
                        Button(String(localized: "Review Changes"), action: onReview)
                            .accessibilityIdentifier("workspace-file-editor.review")
                        Button(String(localized: "Use Disk Version"), role: .destructive, action: onUseDisk)
                            .accessibilityIdentifier("workspace-file-editor.use-disk")
                    }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.bordered)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.themeBgHighlight)
        }
    }
}

/// Disk version against the draft. Replace uses the tag of exactly this read.
struct WorkspaceFileConflictReviewView: View {
    let session: WorkspaceFileEditSession
    let filePath: String
    let onUseDisk: () -> Void
    let onReplace: () -> Void
    let onClose: () -> Void

    @State private var phase: Phase = .loading

    private enum Phase {
        case loading
        case diff(FullScreenCodeContent)
        case resolved
        case unavailable
    }

    var body: some View {
        NavigationStack {
            content
                .safeAreaInset(edge: .bottom, spacing: 0) { actions }
                .navigationTitle(String(localized: "Review Changes"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "Keep Editing"), action: onClose)
                            .accessibilityIdentifier("workspace-file-review.close")
                    }
                }
        }
        .task { await load() }
    }

    /// Plain SwiftUI row, not a toolbar group: the diff body is a UIKit
    /// controller, and the actions must stay visible above it.
    private var actions: some View {
        HStack(spacing: 12) {
            Button(String(localized: "Use Disk Version"), role: .destructive, action: onUseDisk)
                .accessibilityIdentifier("workspace-file-review.use-disk")
            Spacer(minLength: 0)
            if session.status == .conflict, session.reviewedDisk?.etag != nil {
                Button(String(localized: "Replace Disk Version"), action: onReplace)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("workspace-file-review.replace")
            }
        }
        .font(.subheadline.weight(.semibold))
        .buttonStyle(.bordered)
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(.themeBgHighlight)
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .diff(let content):
            EmbeddedFileViewerView(content: content, showsNavigationChrome: false)
        case .resolved:
            ContentUnavailableView(
                String(localized: "Already Saved"),
                systemImage: "checkmark.circle",
                description: Text(String(localized: "The disk version matches your edits."))
            )
        case .unavailable:
            ContentUnavailableView(
                String(localized: "Unable to Load"),
                systemImage: "wifi.exclamationmark",
                description: Text(String(localized: "The disk version could not be read. Your edits were not changed."))
            )
        }
    }

    private func load() async {
        let outcome = await session.reviewDisk()
        let draft = session.currentText
        switch outcome {
        case .snapshot(let snapshot):
            if session.status == .saved {
                phase = .resolved
                return
            }
            let disk = WorkspaceFileTextCodec.decode(snapshot.bytes) ?? ""
            phase = .diff(Self.diffContent(disk: disk, draft: draft, filePath: filePath))
        case .missing:
            phase = .diff(Self.diffContent(disk: "", draft: draft, filePath: filePath))
        case .failed:
            phase = .unavailable
        }
    }

    static func diffContent(disk: String, draft: String, filePath: String) -> FullScreenCodeContent {
        let lines = DiffEngine.compute(old: disk, new: draft)
        return .diff(ToolDiffDocument(
            lines: lines,
            filePath: filePath,
            copyText: DiffEngine.formatUnified(lines)
        ))
    }
}
