import Foundation
import SwiftUI
import UIKit

enum ExtensionStripPillMetrics {
    static let visualHeight: CGFloat = 36
    static let horizontalPadding: CGFloat = 10
    static let verticalPadding: CGFloat = 8
}

enum ExtensionNativeSurfaceLayout {
    static let expandedMaxHeight: CGFloat = 260
}

extension View {
    func extensionGlassPanel(cornerRadius: CGFloat = 18) -> some View {
        self
            .themedSurface(
                .elevatedPanel,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .shadow(color: Color.black.opacity(0.18), radius: 10, x: 0, y: 2)
    }

    func extensionStripPillSurface(isActive: Bool, activeStroke: Color) -> some View {
        self
            .padding(.horizontal, ExtensionStripPillMetrics.horizontalPadding)
            .padding(.vertical, ExtensionStripPillMetrics.verticalPadding)
            .frame(minHeight: ExtensionStripPillMetrics.visualHeight)
            .themedSurface(.elevatedPanel, in: Capsule())
            .overlay {
                if isActive {
                    Capsule()
                        .stroke(activeStroke.opacity(0.45), lineWidth: 1)
                }
            }
            .contentShape(Capsule())
    }
}

private extension View {
    func extensionSubtleInset(cornerRadius: CGFloat = 12) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .background(.themeFg.opacity(0.035), in: shape)
            .overlay {
                shape.stroke(.themeFg.opacity(0.08), lineWidth: 0.5)
            }
    }

    @ViewBuilder
    func extensionFullScreenAccessibilityAction(
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        if enabled {
            accessibilityAction(named: Text("Open Full Screen")) {
                action()
            }
        } else {
            self
        }
    }
}

/// The drawer's capped, scrolling body for one extension entry. Blocks paint in
/// UIKit (`ExtensionNativeBlocksView`); double tap opens the full-screen view.
private struct ExtensionSurfaceExpandedViewport: View {
    let content: ExtensionNativeBlockContent
    let accessibilityIdentifier: String
    let onOpenFullScreen: () -> Void
    var contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10)
    var linkContext: ExtensionSurfaceLinkContext = .empty
    var onOpenURL: ((URL) -> Bool)?

    var body: some View {
        ExtensionNativeBlocksView(
            content: content,
            sizing: .capped(maxHeight: ExtensionNativeSurfaceLayout.expandedMaxHeight),
            contentInsets: contentInsets,
            accessibilityIdentifier: accessibilityIdentifier,
            linkContext: linkContext,
            onOpenURL: onOpenURL,
            onDoubleTap: onOpenFullScreen
        )
        .accessibilityHint("Double tap to open full screen.")
        .accessibilityAction(named: Text("Open Full Screen")) {
            onOpenFullScreen()
        }
    }
}

struct NativeSurfaceViewportScrollContainer<Content: View>: UIViewRepresentable {
    let maxHeight: CGFloat
    let accessibilityIdentifier: String
    let onDoubleTap: (() -> Void)?
    let content: Content

    init(
        maxHeight: CGFloat,
        accessibilityIdentifier: String,
        onDoubleTap: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.maxHeight = maxHeight
        self.accessibilityIdentifier = accessibilityIdentifier
        self.onDoubleTap = onDoubleTap
        self.content = content()
    }

    func makeUIView(context: Context) -> NativeSurfaceViewportContainerView<Content> {
        NativeSurfaceViewportContainerView(
            rootView: content,
            maxHeight: maxHeight,
            accessibilityIdentifier: accessibilityIdentifier,
            onDoubleTap: onDoubleTap
        )
    }

    func updateUIView(_ uiView: NativeSurfaceViewportContainerView<Content>, context: Context) {
        uiView.update(
            rootView: content,
            maxHeight: maxHeight,
            accessibilityIdentifier: accessibilityIdentifier,
            onDoubleTap: onDoubleTap
        )
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: NativeSurfaceViewportContainerView<Content>,
        context: Context
    ) -> CGSize? {
        let measuredWidth = proposal.width ?? uiView.bounds.width
        guard measuredWidth.isFinite, measuredWidth > 0 else { return nil }
        return CGSize(
            width: measuredWidth,
            height: uiView.viewportHeight(for: measuredWidth)
        )
    }
}

final class NativeSurfaceViewportContainerView<Content: View>: UIView, UIGestureRecognizerDelegate {
    private let scrollView = UIScrollView()
    private let hostingController: UIHostingController<Content>
    private var hostedHeightConstraint: NSLayoutConstraint?
    private var maxHeight: CGFloat
    private var onDoubleTap: (() -> Void)?
    private var lastIntrinsicHeight: CGFloat = 0

    private lazy var doubleTapRecognizer: UITapGestureRecognizer = {
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        recognizer.numberOfTapsRequired = 2
        recognizer.cancelsTouchesInView = false
        recognizer.delegate = self
        return recognizer
    }()

    init(
        rootView: Content,
        maxHeight: CGFloat,
        accessibilityIdentifier: String,
        onDoubleTap: (() -> Void)?
    ) {
        hostingController = UIHostingController(rootView: rootView)
        self.maxHeight = maxHeight
        self.onDoubleTap = onDoubleTap
        super.init(frame: .zero)
        setup(accessibilityIdentifier: accessibilityIdentifier)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        return nil
    }

    override var intrinsicContentSize: CGSize {
        let width = bounds.width > 0 ? bounds.width : (window?.windowScene?.screen.bounds.width ?? 390)
        return CGSize(width: UIView.noIntrinsicMetric, height: viewportHeight(for: width))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateScrollBehavior()
    }

    func update(
        rootView: Content,
        maxHeight: CGFloat,
        accessibilityIdentifier: String,
        onDoubleTap: (() -> Void)?
    ) {
        hostingController.rootView = rootView
        hostingController.view.invalidateIntrinsicContentSize()
        self.maxHeight = maxHeight
        self.onDoubleTap = onDoubleTap
        scrollView.accessibilityIdentifier = accessibilityIdentifier
        syncDoubleTapRecognizer()
        setNeedsLayout()
        invalidateIntrinsicContentSize()
    }

    private func setup(accessibilityIdentifier: String) {
        backgroundColor = .clear
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.backgroundColor = .clear
        scrollView.alwaysBounceVertical = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.showsVerticalScrollIndicator = true
        scrollView.accessibilityIdentifier = accessibilityIdentifier
        addSubview(scrollView)
        syncDoubleTapRecognizer()

        let hostedView = hostingController.view
        hostedView?.translatesAutoresizingMaskIntoConstraints = false
        hostedView?.backgroundColor = .clear
        hostedView?.setContentHuggingPriority(.required, for: .vertical)
        hostedView?.setContentCompressionResistancePriority(.required, for: .vertical)
        if let hostedView {
            let heightConstraint = hostedView.heightAnchor.constraint(equalToConstant: 1)
            hostedHeightConstraint = heightConstraint
            scrollView.addSubview(hostedView)
            NSLayoutConstraint.activate([
                hostedView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
                hostedView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
                hostedView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
                hostedView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
                hostedView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
                heightConstraint,
            ])
        }

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func updateScrollBehavior() {
        guard bounds.width > 0 else { return }
        let contentHeight = measuredContentHeight(for: bounds.width)
        hostedHeightConstraint?.constant = max(1, contentHeight)

        let targetHeight = viewportHeight(for: bounds.width)
        let canScrollVertically = contentHeight > maxHeight + 0.5
        scrollView.isScrollEnabled = canScrollVertically
        scrollView.alwaysBounceVertical = canScrollVertically
        clampContentOffset(contentHeight: contentHeight, canScrollVertically: canScrollVertically)

        if abs(targetHeight - lastIntrinsicHeight) > 0.5 {
            lastIntrinsicHeight = targetHeight
            invalidateIntrinsicContentSize()
        }
    }

    func viewportHeight(for width: CGFloat) -> CGFloat {
        let contentHeight = measuredContentHeight(for: width)
        return min(max(1, maxHeight), max(1, contentHeight))
    }

    private func measuredContentHeight(for width: CGFloat) -> CGFloat {
        let measuredHeight = hostingController.sizeThatFits(
            in: CGSize(width: max(1, width), height: CGFloat.greatestFiniteMagnitude)
        ).height
        return measuredHeight.isFinite ? measuredHeight : maxHeight
    }

    private func clampContentOffset(contentHeight: CGFloat, canScrollVertically: Bool) {
        let currentOffset = scrollView.contentOffset
        let maxOffsetY = canScrollVertically ? max(0, contentHeight - scrollView.bounds.height) : 0
        let clampedY = min(max(currentOffset.y, 0), maxOffsetY)
        guard abs(currentOffset.y - clampedY) > 0.5 || abs(currentOffset.x) > 0.5 else { return }
        scrollView.setContentOffset(CGPoint(x: 0, y: clampedY), animated: false)
    }

    private func syncDoubleTapRecognizer() {
        let isInstalled = doubleTapRecognizer.view === scrollView
        if onDoubleTap != nil {
            if !isInstalled {
                scrollView.addGestureRecognizer(doubleTapRecognizer)
            }
        } else if isInstalled {
            scrollView.removeGestureRecognizer(doubleTapRecognizer)
        }
    }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        onDoubleTap?()
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }
}

struct ExtensionNativeSurfaceDetailSheet: View {
    @Environment(\.dismiss) private var dismiss

    let surface: ExtensionUINativeSurface
    let identifierSuffix: String
    let title: String
    let subtitle: String?
    let statusText: String?
    var linkContext: ExtensionSurfaceLinkContext = .empty
    var onOpenURL: ((URL) -> Bool)?
    /// Reads the session's current snapshot for this surface id. Observation
    /// re-renders the reader on each widget update, which the server already
    /// throttles and size-limits; no extra data is fetched. When the surface is
    /// cleared, the reader keeps the last snapshot it showed.
    var liveSurface: (@MainActor () -> ExtensionUINativeSurface?)? = nil
    var usesNavigationBackChrome = false

    @State private var lastLiveSurface: ExtensionUINativeSurface?

    private var displayedSurface: ExtensionUINativeSurface {
        liveSurface?() ?? lastLiveSurface ?? surface
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                if usesNavigationBackChrome {
                    Button(action: { dismiss() }) {
                        Image(systemName: "chevron.backward")
                            .font(.body.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "Back"))
                    .accessibilityIdentifier("extension-native-surface-\(identifierSuffix)-detail-back")
                } else {
                    Button("Done") {
                        dismiss()
                    }
                    .font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier("extension-native-surface-\(identifierSuffix)-detail-done")
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.themeFg)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    if let subtitle = subtitle?.trimmedNonEmpty, subtitle != title {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.themeComment)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 12)

            Divider()

            ExtensionNativeBlocksView(
                content: ExtensionNativeBlockContent(surface: displayedSurface),
                sizing: .fill,
                contentInsets: NSDirectionalEdgeInsets(top: 18, leading: 18, bottom: 18, trailing: 18),
                spacing: 12,
                linkContext: linkContext,
                onOpenURL: onOpenURL
            )
        }
        .themedScrollSurface()
        .accessibilityIdentifier("extension-native-surface-\(identifierSuffix)-detail")
        .onChange(of: liveSurface?()) { _, current in
            if let current { lastLiveSurface = current }
        }
        .horizontalBackSwipeGesture(isEnabled: usesNavigationBackChrome) {
            dismiss()
        }
    }
}

private extension Optional where Wrapped == String {
    var trimmedNonEmpty: String? {
        guard let trimmed = self?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

private struct ExtensionSurfaceHeaderText {
    let title: String
    let subtitle: String?
    let didPromoteStatus: Bool

    init(title rawTitle: String, statusText rawStatusText: String?) {
        let title = rawTitle.trimmedNonEmpty ?? "Extension"
        guard let statusText = rawStatusText.trimmedNonEmpty else {
            self.title = title
            self.subtitle = nil
            self.didPromoteStatus = false
            return
        }

        if statusText.hasExtensionSurfaceWordPrefix(title) {
            self.title = statusText
            self.subtitle = nil
            self.didPromoteStatus = true
        } else {
            self.title = title
            self.subtitle = statusText
            self.didPromoteStatus = false
        }
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var extensionSurfaceWords: [String] {
        lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    func hasExtensionSurfaceWordPrefix(_ prefix: String) -> Bool {
        let words = extensionSurfaceWords
        let prefixWords = prefix.extensionSurfaceWords
        guard !words.isEmpty, !prefixWords.isEmpty, words.count >= prefixWords.count else {
            return false
        }
        return Array(words.prefix(prefixWords.count)) == prefixWords
    }
}

private extension String {
    var extensionAccessibilityIdentifierComponent: String {
        let raw = lowercased().map { character -> Character in
            if character.isLetter || character.isNumber {
                return character
            }
            return "-"
        }
        let collapsed = String(raw)
            .split(separator: "-")
            .joined(separator: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return collapsed.isEmpty ? "widget" : collapsed
    }
}

private enum ExtensionSurfaceStripEntry: Equatable, Identifiable {
    case title(String)
    case status(id: String, key: String, text: String)
    case native(ExtensionNativeSurfaceState, statusText: String?)
    case widget(ExtensionWidgetState, statusText: String?, titleOverride: String?)
    case messageQueue(steeringCount: Int, followUpCount: Int, photoCount: Int, fileCount: Int)

    var id: String {
        switch self {
        case .title: return "title"
        case .status(let id, _, _): return "status:\(id)"
        case .native(let nativeSurface, _): return "native:\(nativeSurface.key)"
        case .widget(let widget, _, _): return "widget:\(widget.key)"
        case .messageQueue: return "message-queue"
        }
    }

    var title: String {
        switch self {
        case .title(let title):
            return title
        case .status(_, let key, _):
            return key
        case .native(let nativeSurface, _):
            let title = nativeSurface.surface.presentation.title?.trimmedNonEmpty
            return title ?? nativeSurface.key.trimmedNonEmpty ?? "Extension"
        case .widget(let widget, let statusText, let titleOverride):
            let rawTitle = titleOverride?.trimmedNonEmpty ?? widget.key.trimmedNonEmpty ?? "Extension widget"
            return ExtensionSurfaceHeaderText(title: rawTitle, statusText: statusText).title
        case .messageQueue:
            return "Message Queue"
        }
    }

    var subtitle: String? {
        switch self {
        case .title:
            return nil
        case .status(_, _, let text):
            return text.trimmedNonEmpty
        case .native(let nativeSurface, let statusText):
            return statusText?.trimmedNonEmpty
                ?? nativeSurface.surface.presentation.subtitle?.trimmedNonEmpty
                ?? Self.nativePreviewText(nativeSurface.surface)
        case .widget(let widget, let statusText, let titleOverride):
            let rawTitle = titleOverride?.trimmedNonEmpty ?? widget.key.trimmedNonEmpty ?? "Extension widget"
            let header = ExtensionSurfaceHeaderText(title: rawTitle, statusText: statusText)
            if let subtitle = header.subtitle {
                return subtitle
            }
            return widget.lines
                .map { ANSIParser.strip($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty && $0 != header.title }
        case .messageQueue(let steeringCount, let followUpCount, _, _):
            return MessageQueueAttachmentPresentation.countSubtitle(
                steeringCount: steeringCount,
                followUpCount: followUpCount
            )
        }
    }

    var mediaSubtitle: String? {
        switch self {
        case .messageQueue(_, _, let photoCount, let fileCount):
            return MessageQueueAttachmentPresentation.mediaHint(
                photoCount: photoCount,
                fileCount: fileCount
            )
        case .title, .status, .native, .widget:
            return nil
        }
    }

    var kindLabel: String {
        switch self {
        case .title: return "title"
        case .status: return "status"
        case .native: return "surface"
        case .widget: return "widget"
        case .messageQueue: return "queue"
        }
    }

    var identifierSuffix: String {
        switch self {
        case .title(let title): return "title-\(title.extensionAccessibilityIdentifierComponent)"
        case .status(_, let key, _): return "status-\(key.extensionAccessibilityIdentifierComponent)"
        case .native(let nativeSurface, _): return nativeSurface.surface.id.extensionAccessibilityIdentifierComponent
        case .widget(let widget, _, _): return widget.key.extensionAccessibilityIdentifierComponent
        case .messageQueue: return "message-queue"
        }
    }

    var stateTone: ExtensionSurfaceStripTone {
        switch self {
        case .native(let nativeSurface, _):
            return Self.nativeTone(nativeSurface.surface)
        case .widget:
            return .accent
        case .messageQueue(let steeringCount, let followUpCount, _, _):
            return steeringCount + followUpCount > 0 ? .success : .neutral
        case .status:
            return .accent
        case .title:
            return .neutral
        }
    }

    var leadingSystemImage: String? {
        switch self {
        case .messageQueue:
            return "text.append"
        case .title, .status, .native, .widget:
            return nil
        }
    }

    private static func nativePreviewText(_ surface: ExtensionUINativeSurface) -> String? {
        for block in surface.nativeDisplayBlocks {
            switch block {
            case .activityList(_, let rows):
                if let row = rows.first {
                    return row.subtitle?.trimmedNonEmpty ?? row.detail?.trimmedNonEmpty ?? row.title.trimmedNonEmpty
                }
            case .text(_, let spans):
                let text = spans.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { return text }
            case .markdown(_, let markdown):
                if let text = markdown.trimmedNonEmpty { return text }
            case .progress(_, let label, let value, let indeterminate):
                if let label = label?.trimmedNonEmpty { return label }
                if indeterminate == true { return "In progress" }
                if let value, value.isFinite { return "\(Int(round(min(max(value, 0), 1) * 100)))%" }
            case .section(_, let title, let subtitle, _):
                if let subtitle = subtitle?.trimmedNonEmpty { return subtitle }
                if let title = title?.trimmedNonEmpty { return title }
            case .terminal(_, let lines, _):
                let text = lines.first?.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
                if let text, !text.isEmpty { return text }
            case .code(_, let language, _):
                return language?.trimmedNonEmpty ?? "Code"
            case .divider, .spacer, .unsupported:
                continue
            }
        }
        return surface.fallbackDisplayLines.first?.trimmedNonEmpty
    }

    private static func nativeTone(_ surface: ExtensionUINativeSurface) -> ExtensionSurfaceStripTone {
        let rows = surface.nativeDisplayBlocks.flatMap { block -> [ExtensionUIActivityRow] in
            if case .activityList(_, let rows) = block { return rows }
            return []
        }
        let states = Set(rows.compactMap(\.state))
        if states.contains("error") { return .danger }
        if states.contains("warning") { return .warning }
        if states.contains("running") { return .running }
        if states.contains("queued") { return .queued }
        if states.contains("success") { return .success }
        return .accent
    }

}

private enum ExtensionSurfaceStripTone {
    case neutral
    case accent
    case running
    case queued
    case success
    case warning
    case danger

    var color: Color {
        switch self {
        case .neutral: return .themeComment
        case .accent: return .themeCyan
        case .running: return .themeBlue
        case .queued: return .themePurple
        case .success: return .themeGreen
        case .warning: return .themeOrange
        case .danger: return .themeRed
        }
    }
}

private struct ExtensionSurfaceStripPill: View {
    let entry: ExtensionSurfaceStripEntry
    let isActive: Bool
    let placement: ExtensionSurfacePlacementGroup
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 7) {
                if let leadingSystemImage = entry.leadingSystemImage {
                    Image(systemName: leadingSystemImage)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(entry.stateTone.color)
                        .accessibilityHidden(true)
                } else {
                    Circle()
                        .fill(entry.stateTone.color)
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                }

                Text(entry.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.themeFg)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 180, alignment: .leading)

                if let subtitle = entry.subtitle?.trimmedNonEmpty {
                    Text(subtitle)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.themeComment)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 150, alignment: .leading)
                }

                if let mediaSubtitle = entry.mediaSubtitle?.trimmedNonEmpty {
                    Text(mediaSubtitle)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.themeFg)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .accessibilityIdentifier("chat.messageQueue.widget.media")
                }

                Image(systemName: isActive ? "chevron.down" : "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.themeComment)
                    .accessibilityHidden(true)
            }
            .extensionStripPillSurface(isActive: isActive, activeStroke: entry.stateTone.color)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("extension-strip-\(placement.accessibilityIdentifierComponent)-pill-\(entry.identifierSuffix)")
        .accessibilityLabel("\(isActive ? "Collapse" : "Expand") \(entry.title) \(entry.kindLabel)")
        .accessibilityValue(accessibilityValueText)
    }

    private var accessibilityValueText: String {
        let parts = [entry.subtitle, entry.mediaSubtitle]
            .compactMap { $0?.trimmedNonEmpty }
        if !parts.isEmpty {
            return parts.joined(separator: " • ")
        }
        return isActive ? "Expanded" : "Collapsed"
    }
}

private struct ExtensionSurfaceDrawer: View {
    let entry: ExtensionSurfaceStripEntry
    let placement: ExtensionSurfacePlacementGroup
    var messageQueue: MessageQueueSurfaceConfiguration?
    var linkContext: ExtensionSurfaceLinkContext = .empty
    var onOpenURL: ((URL) -> Bool)?
    let onCollapse: () -> Void

    @Environment(\.openChatReader) private var openChatReader
    @Environment(ServerConnection.self) private var connection: ServerConnection?
    @State private var nativeDetailPresented = false
    @State private var terminalDetailPresented = false

    private var identifierSuffix: String {
        entry.identifierSuffix
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.themeFg)
                        .lineLimit(1)
                    if let subtitle = entry.subtitle?.trimmedNonEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.themeComment)
                    }
                    if let mediaSubtitle = entry.mediaSubtitle?.trimmedNonEmpty {
                        Text(mediaSubtitle)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.themeFg)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button(action: onCollapse) {
                    Image(systemName: "chevron.up")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.themeComment)
                        .frame(width: 32, height: 32)
                        .background(.themeFg.opacity(0.04), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("extension-strip-\(placement.accessibilityIdentifierComponent)-drawer-collapse")
                .accessibilityLabel("Collapse \(entry.title) \(entry.kindLabel)")
            }

            drawerContent
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .extensionGlassPanel(cornerRadius: 18)
        .accessibilityIdentifier("extension-strip-\(placement.accessibilityIdentifierComponent)-drawer-\(identifierSuffix)")
        .fullScreenCover(isPresented: $nativeDetailPresented) {
            if case .native(let nativeSurface, let statusText) = entry {
                ExtensionNativeSurfaceDetailSheet(
                    surface: nativeSurface.surface,
                    identifierSuffix: identifierSuffix,
                    title: entry.title,
                    subtitle: entry.subtitle,
                    statusText: statusText,
                    linkContext: linkContext,
                    onOpenURL: onOpenURL
                )
            }
        }
        .fullScreenViewer(
            isPresented: $terminalDetailPresented,
            content: terminalFullScreenContent,
            sourceLabel: entry.title
        )
        .extensionFullScreenAccessibilityAction(enabled: supportsFullScreen) {
            openFullScreen()
        }
    }

    @ViewBuilder
    private var drawerContent: some View {
        switch entry {
        case .title(let title):
            Text(title)
                .font(.caption)
                .foregroundStyle(.themeFg)
                .fixedSize(horizontal: false, vertical: true)
        case .status(_, let key, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(key)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.themeComment)
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.themeFg)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .extensionSubtleInset(cornerRadius: 12)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(key), \(text)")
        case .native(let nativeSurface, _):
            ExtensionSurfaceExpandedViewport(
                content: ExtensionNativeBlockContent(surface: nativeSurface.surface),
                accessibilityIdentifier: "extension-native-surface-\(identifierSuffix)-viewport",
                onOpenFullScreen: { openNativeDetail() },
                linkContext: linkContext,
                onOpenURL: onOpenURL
            )
            .extensionSubtleInset(cornerRadius: 12)
        case .widget(let widget, _, _):
            // The terminal block draws its own inset; no outer padding.
            ExtensionSurfaceExpandedViewport(
                content: .terminalLines(widget.lines),
                accessibilityIdentifier: "extension-strip-\(placement.accessibilityIdentifierComponent)-terminal-\(identifierSuffix)",
                onOpenFullScreen: { openTerminalDetail() },
                contentInsets: NSDirectionalEdgeInsets(),
                linkContext: linkContext,
                onOpenURL: onOpenURL
            )
        case .messageQueue:
            if let messageQueue {
                MessageQueueContainer(configuration: messageQueue, presentation: .drawer)
            }
        }
    }

    private var supportsFullScreen: Bool {
        switch entry {
        case .native, .widget: return true
        case .title, .status, .messageQueue: return false
        }
    }

    private var terminalFullScreenContent: FullScreenCodeContent {
        guard case .widget(let widget, _, _) = entry else {
            return .terminal(content: "", command: nil)
        }
        return .terminal(content: widget.lines.joined(separator: "\n"), command: nil)
    }

    private func openFullScreen() {
        switch entry {
        case .native:
            openNativeDetail()
        case .widget:
            openTerminalDetail()
        case .title, .status, .messageQueue:
            break
        }
    }

    private func openNativeDetail() {
        guard case .native(let nativeSurface, let statusText) = entry else { return }
        if let openChatReader {
            openChatReader(
                .extensionNative(
                    ExtensionNativeReaderContent(
                        surface: nativeSurface.surface,
                        identifierSuffix: identifierSuffix,
                        title: entry.title,
                        subtitle: entry.subtitle,
                        statusText: statusText,
                        linkContext: linkContext,
                        onOpenURL: onOpenURL,
                        liveSurface: liveSurfaceLookup(id: nativeSurface.surface.id)
                    )
                )
            )
            return
        }
        nativeDetailPresented = true
    }

    /// Looks the surface up by protocol id each time the reader renders, so a
    /// pushed reader follows updates the drawer would show.
    private func liveSurfaceLookup(id: String) -> (@MainActor () -> ExtensionUINativeSurface?)? {
        guard let sessionID = linkContext.sessionID else { return nil }
        return { [weak connection] in
            connection?.extensionSurfaceBySession[sessionID]?.nativeSurfaces[id]?.surface
        }
    }

    private func openTerminalDetail() {
        if let openChatReader {
            openChatReader(.document(content: terminalFullScreenContent))
            return
        }
        terminalDetailPresented = true
    }
}

struct ExtensionSurfacePanel<LeadingStripContent: View>: View {
    let surface: ExtensionSurfaceState
    let placement: ExtensionSurfacePlacementGroup
    var messageQueue: MessageQueueSurfaceConfiguration? = nil
    var linkContext: ExtensionSurfaceLinkContext = .empty
    var onOpenURL: ((URL) -> Bool)? = nil
    var onExpandedEntryChange: ((Bool) -> Void)? = nil
    var collapseRequestID: Int = 0
    var showsLeadingStripContent = false
    var leadingStripContent: LeadingStripContent

    init(
        surface: ExtensionSurfaceState,
        placement: ExtensionSurfacePlacementGroup,
        messageQueue: MessageQueueSurfaceConfiguration? = nil,
        linkContext: ExtensionSurfaceLinkContext = .empty,
        onOpenURL: ((URL) -> Bool)? = nil,
        onExpandedEntryChange: ((Bool) -> Void)? = nil,
        collapseRequestID: Int = 0,
        showsLeadingStripContent: Bool = false,
        @ViewBuilder leadingStripContent: () -> LeadingStripContent = { EmptyView() }
    ) {
        self.surface = surface
        self.placement = placement
        self.messageQueue = messageQueue
        self.linkContext = linkContext
        self.onOpenURL = onOpenURL
        self.onExpandedEntryChange = onExpandedEntryChange
        self.collapseRequestID = collapseRequestID
        self.showsLeadingStripContent = showsLeadingStripContent
        self.leadingStripContent = leadingStripContent()
    }

    @State private var expandedEntryID: String?

    private var sortedStatuses: [(id: String, key: String, text: String)] {
        surface.standaloneStatusEntries()
    }

    private var entries: [ExtensionSurfacePanelEntry] {
        surface.widgetEntries(in: placement)
    }

    private var stripEntries: [ExtensionSurfaceStripEntry] {
        var result: [ExtensionSurfaceStripEntry] = []
        if placement.showsChrome,
           let title = surface.title?.trimmedNonEmpty {
            result.append(.title(title))
        }
        if placement.showsChrome {
            result.append(contentsOf: sortedStatuses.map { .status(id: $0.id, key: $0.key, text: $0.text) })
        }
        result.append(contentsOf: entries.map { entry in
            switch entry {
            case .native(let nativeSurface):
                return .native(
                    nativeSurface,
                    statusText: surface.attachedStatusText(
                        for: nativeSurface.key,
                        extensionScopeId: nativeSurface.extensionScopeId
                    )
                )
            case .widget(let widget):
                return .widget(
                    widget,
                    statusText: surface.attachedStatusText(
                        for: widget.key,
                        extensionScopeId: widget.extensionScopeId
                    ),
                    titleOverride: surface.displayTitle(for: widget)
                )
            }
        })
        if let messageQueue, messageQueue.hasVisibleEntry {
            let media = MessageQueueAttachmentPresentation.mediaCounts(in: messageQueue.queue)
            result.append(.messageQueue(
                steeringCount: messageQueue.queue.steering.count,
                followUpCount: messageQueue.queue.followUp.count,
                photoCount: media.photos,
                fileCount: media.files
            ))
        }
        return result
    }

    private var activeEntry: ExtensionSurfaceStripEntry? {
        guard let expandedEntryID else { return nil }
        return stripEntries.first { $0.id == expandedEntryID }
    }

    private var showsStrip: Bool {
        showsLeadingStripContent || !stripEntries.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsStrip {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        if showsLeadingStripContent {
                            leadingStripContent
                        }
                        ForEach(stripEntries) { entry in
                            ExtensionSurfaceStripPill(
                                entry: entry,
                                isActive: activeEntry?.id == entry.id,
                                placement: placement,
                                onTap: { toggle(entry) }
                            )
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("extension-strip-\(placement.accessibilityIdentifierComponent)-collapsed")
            }

            if let activeEntry {
                ExtensionSurfaceDrawer(
                    entry: activeEntry,
                    placement: placement,
                    messageQueue: messageQueue,
                    linkContext: linkContext,
                    onOpenURL: onOpenURL,
                    onCollapse: collapseActiveEntry
                )
                .id(activeEntry.id)
                .transition(.opacity)
            }
        }
        .onChange(of: collapseRequestID) { _, _ in
            collapseActiveEntry()
        }
        .onChange(of: stripEntries.map(\.id)) { _, ids in
            if let expandedEntryID, !ids.contains(expandedEntryID) {
                self.expandedEntryID = nil
                onExpandedEntryChange?(false)
            }
        }
    }

    private func toggle(_ entry: ExtensionSurfaceStripEntry) {
        withAnimation(.easeOut(duration: 0.10)) {
            expandedEntryID = expandedEntryID == entry.id ? nil : entry.id
        }
        onExpandedEntryChange?(expandedEntryID != nil)
    }

    private func collapseActiveEntry() {
        withAnimation(.easeOut(duration: 0.10)) {
            expandedEntryID = nil
        }
        onExpandedEntryChange?(false)
    }
}

private extension ExtensionSurfacePlacementGroup {
    var accessibilityIdentifierComponent: String {
        switch self {
        case .aboveEditor: return "aboveEditor"
        case .belowEditor: return "belowEditor"
        }
    }
}
