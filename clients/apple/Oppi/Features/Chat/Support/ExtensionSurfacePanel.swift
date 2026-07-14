import Foundation
import SwiftUI
import UIKit

private extension View {
    func extensionGlassPanel(cornerRadius: CGFloat = 18) -> some View {
        self
            .themedSurface(
                .elevatedPanel,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .shadow(color: Color.black.opacity(0.18), radius: 10, x: 0, y: 2)
    }

    func extensionStripGlassPanel(cornerRadius: CGFloat = 18) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .glassEffect(.regular, in: shape)
            .shadow(color: Color.black.opacity(0.08), radius: 10, x: 0, y: 2)
    }

    func extensionGlassInset(cornerRadius: CGFloat = 12) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .background(Color.themeFg.opacity(0.04), in: shape)
            .overlay {
                shape.stroke(Color.themeFg.opacity(0.08), lineWidth: 0.5)
            }
    }

    func extensionSubtleInset(cornerRadius: CGFloat = 12) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .background(Color.themeFg.opacity(0.035), in: shape)
            .overlay {
                shape.stroke(Color.themeFg.opacity(0.08), lineWidth: 0.5)
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

private struct ExtensionProgressBar: View {
    let value: Double
    var height: CGFloat = 5

    private var clampedValue: Double {
        min(max(value, 0), 1)
    }

    var body: some View {
        GeometryReader { proxy in
            let width = max(0, min(proxy.size.width, proxy.size.width * CGFloat(clampedValue)))

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.themeFg.opacity(0.12))

                Capsule()
                    .fill(Color.themeFg.opacity(0.82))
                    .frame(width: width)
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

private struct ExtensionDisclosureChevron: View {
    let isExpanded: Bool

    var body: some View {
        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.themeComment)
            .frame(width: 24, height: 24)
            .background(Color.themeFg.opacity(0.06), in: Circle())
            .accessibilityHidden(true)
    }
}

private struct ExtensionWidgetLinesView: View {
    let lines: [String]
    var scrollIdentifier: String? = nil
    var onOpenFullScreen: (() -> Void)? = nil

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    ExtensionWidgetLineView(line: line)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier(scrollIdentifier ?? "extension-widget-lines-scroll")
        .extensionWidgetFullScreenActivation(onOpenFullScreen)
        .extensionGlassInset(cornerRadius: 12)
    }
}

private extension View {
    @ViewBuilder
    func extensionWidgetFullScreenActivation(_ onOpenFullScreen: (() -> Void)?) -> some View {
        if let onOpenFullScreen {
            self
                .accessibilityHint("Double tap to open full screen.")
                .accessibilityAction(named: Text("Open Full Screen")) {
                    onOpenFullScreen()
                }
                .highPriorityGesture(
                    TapGesture(count: 2).onEnded {
                        onOpenFullScreen()
                    }
                )
        } else {
            self
        }
    }
}

struct ExtensionNativeSurfaceView: View {
    let surface: ExtensionUINativeSurface
    let statusText: String?
    var onOpenURL: ((URL) -> Bool)?

    @State private var isExpanded = false
    @State private var isDetailPresented = false

    private static let maxExpandedViewportHeight: CGFloat = 280

    private var displayBlocks: [ExtensionUINativeBlock] {
        surface.nativeDisplayBlocks
    }

    private var titleText: String {
        let title = surface.presentation.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? "Extension" : title
    }

    private var activityRows: [ExtensionUIActivityRow] {
        displayBlocks.flatMap { block -> [ExtensionUIActivityRow] in
            if case .activityList(_, let rows) = block { return rows }
            return []
        }
    }

    private var summaryText: String? {
        guard !activityRows.isEmpty else { return nil }
        let activeCount = activityRows.filter { row in
            row.state == "running" || row.state == "queued"
        }.count
        if activeCount > 0 {
            return "\(activeCount) active"
        }
        return nil
    }

    private var previewText: String? {
        if let activity = activityRows.first {
            return activity.title.trimmedNonEmpty
        }
        if case .markdown(_, let markdown)? = displayBlocks.first {
            return markdown.trimmedNonEmpty
        }
        if case .text(_, let spans)? = displayBlocks.first {
            let text = spans.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        return surface.fallbackDisplayLines.first?.trimmedNonEmpty
    }

    private var headerText: ExtensionSurfaceHeaderText {
        ExtensionSurfaceHeaderText(title: titleText, statusText: statusText)
    }

    private var identifierSuffix: String {
        surface.id.extensionAccessibilityIdentifierComponent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(headerText.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.themeFg)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if let subtitle = headerText.subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.themeComment)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    } else if let previewText {
                        Text(previewText)
                            .font(.caption)
                            .foregroundStyle(.themeComment)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let summaryText {
                    StatusPill(
                        text: summaryText,
                        systemImage: "play.circle.fill",
                        tone: .working,
                        emphasis: .quiet,
                        size: .small
                    )
                }
            }
            .frame(minHeight: 52)
            .contentShape(Rectangle())
            .gesture(activationGesture)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("\(isExpanded ? "Collapse" : "Expand") \(headerText.title) preview")
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint("Tap to expand. Double tap to open full screen.")
            .accessibilityAction {
                toggleExpanded()
            }
            .accessibilityAction(named: Text("Open Full Screen")) {
                openDetail()
            }

            if isExpanded {
                ExtensionNativeSurfaceExpandedViewport(
                    surface: surface,
                    identifierSuffix: identifierSuffix,
                    maxHeight: Self.maxExpandedViewportHeight,
                    onOpenFullScreen: openDetail,
                    onOpenURL: onOpenURL
                )
                .transition(.opacity)
            }
        }
        .highPriorityGesture(
            TapGesture(count: 2).onEnded {
                if isExpanded {
                    openDetail()
                }
            }
        )
        .fullScreenCover(isPresented: $isDetailPresented) {
            ExtensionNativeSurfaceDetailSheet(
                surface: surface,
                identifierSuffix: identifierSuffix,
                title: headerText.title,
                subtitle: headerText.subtitle ?? previewText,
                statusText: statusText,
                onOpenURL: onOpenURL
            )
        }
    }

    private var activationGesture: some Gesture {
        TapGesture(count: 2)
            .exclusively(before: TapGesture())
            .onEnded { value in
                switch value {
                case .first:
                    openDetail()
                case .second:
                    toggleExpanded()
                }
            }
    }

    private func toggleExpanded() {
        withAnimation(.easeOut(duration: 0.10)) {
            isExpanded.toggle()
        }
    }

    private func openDetail() {
        isDetailPresented = true
    }
}

private struct ExtensionNativeSurfaceExpandedViewport: View {
    let surface: ExtensionUINativeSurface
    let identifierSuffix: String
    let maxHeight: CGFloat
    let onOpenFullScreen: () -> Void
    var onOpenURL: ((URL) -> Bool)?

    private var displayBlocks: [ExtensionUINativeBlock] {
        surface.nativeDisplayBlocks
    }

    var body: some View {
        NativeSurfaceViewportScrollContainer(
            maxHeight: maxHeight,
            accessibilityIdentifier: "extension-native-surface-\(identifierSuffix)-viewport",
            onDoubleTap: onOpenFullScreen
        ) {
            VStack(alignment: .leading, spacing: 10) {
                if displayBlocks.isEmpty {
                    let fallbackLines = surface.fallbackDisplayLines
                    if !fallbackLines.isEmpty {
                        ExtensionWidgetLinesView(lines: fallbackLines)
                    }
                } else {
                    ForEach(Array(displayBlocks.enumerated()), id: \.offset) { _, block in
                        ExtensionNativeBlockView(
                            block: block,
                            isDetail: true,
                            onOpenURL: onOpenURL
                        )
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityHint("Double tap to open full screen.")
        .accessibilityAction(named: Text("Open Full Screen")) {
            onOpenFullScreen()
        }
        .extensionSubtleInset(cornerRadius: 12)
    }
}

private struct NativeSurfaceViewportScrollContainer<Content: View>: UIViewRepresentable {
    let maxHeight: CGFloat
    let accessibilityIdentifier: String
    let onDoubleTap: () -> Void
    let content: Content

    init(
        maxHeight: CGFloat,
        accessibilityIdentifier: String,
        onDoubleTap: @escaping () -> Void,
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

private final class NativeSurfaceViewportContainerView<Content: View>: UIView, UIGestureRecognizerDelegate {
    private let scrollView = UIScrollView()
    private let hostingController: UIHostingController<Content>
    private var hostedHeightConstraint: NSLayoutConstraint?
    private var maxHeight: CGFloat
    private var onDoubleTap: () -> Void
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
        onDoubleTap: @escaping () -> Void
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
        onDoubleTap: @escaping () -> Void
    ) {
        hostingController.rootView = rootView
        hostingController.view.invalidateIntrinsicContentSize()
        self.maxHeight = maxHeight
        self.onDoubleTap = onDoubleTap
        scrollView.accessibilityIdentifier = accessibilityIdentifier
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
        scrollView.addGestureRecognizer(doubleTapRecognizer)
        addSubview(scrollView)

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

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        onDoubleTap()
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }
}

private struct ExtensionNativeSurfaceDetailSheet: View {
    @Environment(\.dismiss) private var dismiss

    let surface: ExtensionUINativeSurface
    let identifierSuffix: String
    let title: String
    let subtitle: String?
    let statusText: String?
    var onOpenURL: ((URL) -> Bool)?

    private var displayBlocks: [ExtensionUINativeBlock] {
        surface.nativeDisplayBlocks
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                Button("Done") {
                    dismiss()
                }
                .font(.subheadline.weight(.semibold))
                .accessibilityIdentifier("extension-native-surface-\(identifierSuffix)-detail-done")

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

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if displayBlocks.isEmpty {
                        let fallbackLines = surface.fallbackDisplayLines
                        if !fallbackLines.isEmpty {
                            ExtensionWidgetLinesView(lines: fallbackLines)
                        }
                    } else {
                        ForEach(Array(displayBlocks.enumerated()), id: \.offset) { _, block in
                            ExtensionNativeBlockView(
                                block: block,
                                isDetail: true,
                                onOpenURL: onOpenURL
                            )
                        }
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color.themeBg.ignoresSafeArea())
        .accessibilityIdentifier("extension-native-surface-\(identifierSuffix)-detail")
    }
}

private struct ExtensionNativeBlockView: View {
    let block: ExtensionUINativeBlock
    var isDetail: Bool = false
    var onOpenURL: ((URL) -> Bool)?

    var body: some View {
        switch block {
        case .text(_, let spans):
            ExtensionNativeTextSpansView(spans: spans, onOpenURL: onOpenURL)
        case .markdown(_, let markdown):
            ExtensionNativeMarkdownView(markdown: markdown)
        case .section(_, let title, let subtitle, let blocks):
            VStack(alignment: .leading, spacing: 6) {
                if let title, !title.isEmpty {
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.themeFg)
                }
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.themeComment)
                }
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, child in
                    ExtensionNativeBlockView(block: child, isDetail: isDetail, onOpenURL: onOpenURL)
                }
            }
            .padding(10)
            .extensionGlassInset(cornerRadius: 12)
        case .activityList(_, let rows):
            ExtensionNativeActivityListView(rows: rows, startsExpanded: isDetail, onOpenURL: onOpenURL)
        case .progress(let base, let label, let value, let indeterminate):
            ExtensionNativeProgressBlockView(
                base: base,
                label: label,
                value: value,
                indeterminate: indeterminate
            )
        case .terminal(_, let lines):
            ExtensionNativeTerminalLinesView(lines: lines, onOpenURL: onOpenURL)
        case .code(_, _, let text):
            ExtensionWidgetLinesView(lines: text.components(separatedBy: .newlines))
        case .divider:
            Divider()
        case .spacer(_, let size):
            Color.clear.frame(height: spacerHeight(size))
        case .unsupported:
            EmptyView()
        }
    }

    private func spacerHeight(_ size: String?) -> CGFloat {
        switch size {
        case "large": return 16
        case "medium": return 10
        default: return 6
        }
    }
}

private struct ExtensionNativeProgressBlockView: View {
    let base: ExtensionUIBlockBase
    let label: String?
    let value: Double?
    let indeterminate: Bool?

    private var trimmedLabel: String? {
        label.trimmedNonEmpty
    }

    private var normalizedValue: Double? {
        guard let value, value.isFinite else { return nil }
        return min(max(value, 0), 1)
    }

    private var isIndeterminate: Bool {
        indeterminate == true || normalizedValue == nil
    }

    private var accessibilityLabel: String {
        base.accessibility?.label.trimmedNonEmpty ?? trimmedLabel ?? "Progress"
    }

    private var accessibilityValue: String {
        if let value = base.accessibility?.value.trimmedNonEmpty {
            return value
        }
        if isIndeterminate {
            return "In progress"
        }
        if let normalizedValue {
            return "\(Int(round(normalizedValue * 100))) percent"
        }
        return ""
    }

    var body: some View {
        Group {
            if isIndeterminate {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.themeBlue)

                    if let trimmedLabel {
                        Text(trimmedLabel)
                            .font(.caption)
                            .foregroundStyle(.themeFg)
                    }
                }
                .frame(minHeight: trimmedLabel == nil ? 18 : 28, alignment: .leading)
            } else if let normalizedValue {
                VStack(alignment: .leading, spacing: 6) {
                    if let trimmedLabel {
                        Text(trimmedLabel)
                            .font(.caption)
                            .foregroundStyle(.themeFg)
                    }

                    ExtensionProgressBar(value: normalizedValue)
                }
                .frame(minHeight: trimmedLabel == nil ? 10 : 30, alignment: .leading)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
    }
}

private struct ExtensionNativeMarkdownView: View {
    let markdown: String

    private var attributedMarkdown: AttributedString? {
        try? AttributedString(markdown: markdown)
    }

    var body: some View {
        Group {
            if let attributedMarkdown {
                Text(attributedMarkdown)
            } else {
                Text(markdown)
            }
        }
        .font(.caption)
        .foregroundStyle(.themeFg)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ExtensionNativeTextSpansView: View {
    let spans: [ExtensionUITextSpan]
    var font: Font = .caption
    var onOpenURL: ((URL) -> Bool)?

    var body: some View {
        Text(spans.extensionNativeAttributedString)
            .font(font)
            .foregroundStyle(.themeFg)
            .fixedSize(horizontal: false, vertical: true)
            .environment(\.openURL, OpenURLAction { url in
                onOpenURL?(url) == true ? .handled : .systemAction
            })
    }
}

private struct ExtensionNativeTerminalLinesView: View {
    let lines: [[ExtensionUITextSpan]]
    var onOpenURL: ((URL) -> Bool)?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    ExtensionNativeTextSpansView(
                        spans: line,
                        font: .caption2.monospaced(),
                        onOpenURL: onOpenURL
                    )
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .extensionGlassInset(cornerRadius: 12)
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

extension Array where Element == ExtensionUITextSpan {
    var extensionNativeAttributedString: AttributedString {
        var result = AttributedString()
        for span in self {
            result.append(span.extensionNativeAttributedString)
        }
        return result
    }
}

private extension ExtensionUITextSpan {
    var extensionNativeAttributedString: AttributedString {
        var result = AttributedString(text)
        let traits = normalizedTraits
        var intent = InlinePresentationIntent()

        if traits.contains("bold") {
            intent.insert(.stronglyEmphasized)
        }
        if traits.contains("italic") {
            intent.insert(.emphasized)
        }
        if !intent.isEmpty {
            result.inlinePresentationIntent = intent
        }

        if traits.contains("underline") {
            result.underlineStyle = .single
        }
        if traits.contains("strikethrough") {
            result.strikethroughStyle = .single
        }

        let url = nativeURL
        if let color = nativeRoleColor {
            result.foregroundColor = color
        } else if url != nil {
            result.foregroundColor = .themeCyan
        }

        if role?.lowercased() == "code" || traits.contains("monospaced") {
            result.font = .system(.caption, design: .monospaced)
        }

        if let url {
            result.link = url
            result.underlineStyle = .single
        }

        return result
    }

    var normalizedTraits: Set<String> {
        Set((traits ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
    }

    var nativeURL: URL? {
        guard let link,
              let url = URL(string: link),
              url.scheme?.isEmpty == false else {
            return nil
        }
        return url
    }

    var nativeRoleColor: Color? {
        switch role?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "primary":
            .themeFg
        case "secondary":
            .themeComment
        case "muted":
            .themeFgDim
        case "accent":
            .themeCyan
        case "success":
            .themeGreen
        case "warning":
            .themeOrange
        case "danger":
            .themeRed
        case "code":
            .themeYellow
        default:
            nil
        }
    }
}

private struct ExtensionNativeActivityListView: View {
    let rows: [ExtensionUIActivityRow]
    var startsExpanded: Bool = false
    var onOpenURL: ((URL) -> Bool)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(rows) { row in
                ExtensionNativeActivityRowView(
                    row: row,
                    startsExpanded: startsExpanded,
                    onOpenURL: onOpenURL
                )
            }
        }
    }
}

private struct ExtensionNativeActivityRowView: View {
    @Environment(\.openURL) private var openURL

    let row: ExtensionUIActivityRow
    var startsExpanded: Bool = false
    var onOpenURL: ((URL) -> Bool)?

    @State private var isExpanded = false

    private var childRows: [ExtensionUIActivityRow] {
        row.children ?? []
    }

    private var isExpandedForDisplay: Bool {
        startsExpanded || isExpanded
    }

    private var canExpandInline: Bool {
        guard linkedURL == nil else { return false }
        if !childRows.isEmpty { return true }
        if row.title.count > 34 || row.title.contains("\n") { return true }
        if let subtitle = row.subtitle, subtitle.count > 32 || subtitle.contains("\n") { return true }
        if let detail = row.detail, detail.count > 44 || detail.contains("\n") { return true }
        return false
    }

    var body: some View {
        let content = ExtensionNativeActivityRowContent(
            row: row,
            showsNavigationCue: linkedURL != nil,
            showsDisclosureCue: linkedURL == nil && canExpandInline && !startsExpanded,
            isExpanded: isExpandedForDisplay
        )
        Group {
            if let url = linkedURL {
                Button {
                    if onOpenURL?(url) != true {
                        openURL(url)
                    }
                } label: {
                    content
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(accessibilityLabel)
                .accessibilityValue(accessibilityValue)
                .accessibilityHint("Opens the related session")
                .accessibilityIdentifier(activityRowAccessibilityIdentifier)
            } else if canExpandInline && !startsExpanded {
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        isExpanded.toggle()
                    }
                } label: {
                    content
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(accessibilityLabel)
                .accessibilityValue(accessibilityValue)
                .accessibilityHint(isExpanded ? "Collapse task text" : "Show full task text")
                .accessibilityIdentifier(activityRowAccessibilityIdentifier)
            } else {
                content
            }

            if isExpandedForDisplay && !childRows.isEmpty {
                ExtensionNativeActivityListView(
                    rows: childRows,
                    startsExpanded: startsExpanded,
                    onOpenURL: onOpenURL
                )
                .padding(.leading, 22)
            }
        }
    }

    private var linkedURL: URL? {
        guard let link = row.link,
              let url = URL(string: link),
              url.scheme?.isEmpty == false else {
            return nil
        }
        return url
    }

    private var activityRowAccessibilityIdentifier: String {
        "extension.native.activity.row.\(row.id)"
    }

    private var accessibilityLabel: String {
        [row.title, row.subtitle, row.detail]
            .compactMap { value in
                let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return trimmed.isEmpty ? nil : trimmed
            }
            .joined(separator: ", ")
    }

    private var accessibilityValue: String {
        [stateAccessibilityText, progressAccessibilityText]
            .compactMap { value in
                let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return trimmed.isEmpty ? nil : trimmed
            }
            .joined(separator: ", ")
    }

    private var stateAccessibilityText: String? {
        switch row.state {
        case "running": return "Working"
        case "success": return "Done"
        case "warning": return "Warning"
        case "error": return "Error"
        case "queued": return "Queued"
        case "inactive": return "Not started"
        default: return nil
        }
    }

    private var progressAccessibilityText: String? {
        guard let progress = row.progress, progress.isFinite else { return nil }
        let normalized = min(max(progress, 0), 1)
        return "\(Int(round(normalized * 100))) percent"
    }
}

private struct ExtensionNativeActivityRowContent: View {
    let row: ExtensionUIActivityRow
    let showsNavigationCue: Bool
    let showsDisclosureCue: Bool
    let isExpanded: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            stateMarker
                .frame(width: 14, height: 14)
                .padding(.top, 3)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(row.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.themeFg)
                    .lineLimit(isExpanded ? nil : 2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)

                if let subtitle = row.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.themeComment)
                        .lineLimit(isExpanded ? nil : 1)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let detail = row.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.themeComment)
                        .lineLimit(isExpanded ? nil : 2)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let progress = normalizedProgress {
                    ExtensionProgressBar(value: progress, height: 4)
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if showsNavigationCue || showsDisclosureCue {
                Image(systemName: showsDisclosureCue && isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.themeComment)
                    .padding(.top, 3)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .frame(minHeight: showsNavigationCue || showsDisclosureCue ? 44 : 34, alignment: .center)
        .background(
            Color.themeFg.opacity(rowHighlightOpacity),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.themeComment.opacity(rowBorderOpacity), lineWidth: 1)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
        .accessibilityIdentifier("extension.native.activity.row.\(row.id)")
    }

    private var rowAccentColor: Color {
        switch row.state {
        case "running": return .themeBlue
        case "success": return .themeGreen
        case "warning": return .themeOrange
        case "error": return .themeRed
        case "queued": return .themePurple
        default: return .themeComment
        }
    }

    private var rowHighlightOpacity: Double {
        switch row.state {
        case "running", "warning", "error": return 0.05
        default: return 0
        }
    }

    private var rowBorderOpacity: Double {
        switch row.state {
        case "running", "warning", "error": return 0.16
        default: return 0
        }
    }

    private var markerSymbolName: String {
        switch row.state {
        case "running": return "play.circle.fill"
        case "success": return "checkmark.circle.fill"
        case "warning": return "exclamationmark.circle.fill"
        case "error": return "xmark.circle.fill"
        case "queued": return "clock.circle.fill"
        case "inactive": return "circle"
        default: return "circle.fill"
        }
    }

    private var markerSymbolWeight: Font.Weight {
        row.state == "inactive" ? .regular : .semibold
    }

    private var stateMarker: some View {
        Image(systemName: markerSymbolName)
            .font(.system(size: 14, weight: markerSymbolWeight))
            .foregroundStyle(rowAccentColor)
    }

    private var normalizedProgress: Double? {
        guard let progress = row.progress, progress.isFinite else { return nil }
        return min(max(progress, 0), 1)
    }

    private var accessibilityLabel: String {
        [row.title, row.subtitle, row.detail]
            .compactMap { value in
                let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return trimmed.isEmpty ? nil : trimmed
            }
            .joined(separator: ", ")
    }

    private var accessibilityValue: String {
        [stateAccessibilityText, progressAccessibilityText]
            .compactMap { value in
                let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return trimmed.isEmpty ? nil : trimmed
            }
            .joined(separator: ", ")
    }

    private var stateAccessibilityText: String? {
        switch row.state {
        case "running": return "Working"
        case "success": return "Done"
        case "warning": return "Warning"
        case "error": return "Error"
        case "queued": return "Queued"
        case "inactive": return "Not started"
        default: return nil
        }
    }

    private var progressAccessibilityText: String? {
        guard let normalizedProgress else { return nil }
        return "\(Int(round(normalizedProgress * 100))) percent"
    }
}

private struct ExtensionWidgetTerminalLineText: UIViewRepresentable {
    let line: String
    let baseForeground: Color

    func makeUIView(context: Context) -> UILabel {
        let label = UILabel()
        label.backgroundColor = .clear
        label.numberOfLines = 1
        label.lineBreakMode = .byClipping
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.setContentHuggingPriority(.required, for: .vertical)
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        return label
    }

    func updateUIView(_ uiView: UILabel, context: Context) {
        uiView.attributedText = ANSIParser.attributedString(from: line, baseForeground: baseForeground)
        uiView.accessibilityLabel = ANSIParser.strip(line)
    }
}

private struct ExtensionWidgetLineView: View {
    let line: String

    private var trimmedLine: String {
        ANSIParser.strip(line).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isHeader: Bool {
        trimmedLine.hasPrefix("● ") || trimmedLine.hasPrefix("○ ")
    }

    private var isActivity: Bool {
        trimmedLine.contains("⎿")
    }

    private var markerColor: Color {
        if trimmedLine.hasPrefix("●") { return .themeGreen }
        if trimmedLine.hasPrefix("○") { return .themeComment }
        if trimmedLine.contains("✗") { return .themeRed }
        if trimmedLine.contains("✓") { return .themeGreen }
        if trimmedLine.contains("⠋") || trimmedLine.contains("⠙") || trimmedLine.contains("⠹") || trimmedLine.contains("⠸") || trimmedLine.contains("⠼") || trimmedLine.contains("⠴") || trimmedLine.contains("⠦") || trimmedLine.contains("⠧") || trimmedLine.contains("⠇") || trimmedLine.contains("⠏") {
            return .themeOrange
        }
        return .themeComment
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if isHeader {
                Circle()
                    .fill(markerColor)
                    .frame(width: 7, height: 7)
                    .padding(.top, -1)
                Text(String(trimmedLine.dropFirst(2)))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.themeFg)
                    .lineLimit(1)
            } else {
                ExtensionWidgetTerminalLineText(
                    line: line,
                    baseForeground: isActivity ? .themeComment : .themeFg
                )
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel(trimmedLine.isEmpty ? line : trimmedLine)
    }
}

enum ExtensionSurfacePlacementGroup {
    case aboveEditor
    case belowEditor

    var showsChrome: Bool {
        self == .aboveEditor
    }

    func includes(widgetPlacement: String?) -> Bool {
        switch self {
        case .aboveEditor:
            return widgetPlacement != "belowEditor"
        case .belowEditor:
            return widgetPlacement == "belowEditor"
        }
    }
}

enum ExtensionSurfacePanelEntry: Equatable, Identifiable {
    case native(ExtensionNativeSurfaceState)
    case widget(ExtensionWidgetState)

    var id: String {
        switch self {
        case .native(let nativeSurface): return "native:\(nativeSurface.key)"
        case .widget(let widget): return "widget:\(widget.key)"
        }
    }

    var order: Int {
        switch self {
        case .native(let nativeSurface): return nativeSurface.order
        case .widget(let widget): return widget.order
        }
    }

    var sortKey: String {
        switch self {
        case .native(let nativeSurface): return nativeSurface.key
        case .widget(let widget): return widget.key
        }
    }
}

extension ExtensionSurfaceState {
    func widgetEntries(in placement: ExtensionSurfacePlacementGroup) -> [ExtensionSurfacePanelEntry] {
        let nativeEntries = nativeSurfaces.values
            .filter { placement.includes(widgetPlacement: $0.placement) && $0.hasVisibleContent }
            .map(ExtensionSurfacePanelEntry.native)
        let textEntries = widgets.values
            .filter { placement.includes(widgetPlacement: $0.placement) && !$0.lines.isEmpty }
            .map(ExtensionSurfacePanelEntry.widget)

        return (nativeEntries + textEntries).sorted { lhs, rhs in
            if lhs.order != rhs.order { return lhs.order < rhs.order }
            return lhs.sortKey.localizedCaseInsensitiveCompare(rhs.sortKey) == .orderedAscending
        }
    }

    private func visibleSurfaceCount(in extensionScopeId: String?) -> Int {
        let widgetCount = widgets.values.filter { widget in
            widget.extensionScopeId == extensionScopeId && !widget.lines.isEmpty
        }.count
        let nativeCount = nativeSurfaces.values.filter { nativeSurface in
            nativeSurface.extensionScopeId == extensionScopeId && nativeSurface.hasVisibleContent
        }.count
        return widgetCount + nativeCount
    }

    private func statusCount(in extensionScopeId: String?) -> Int {
        statuses.values.filter { status in
            status.extensionScopeId == extensionScopeId
                && !status.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count
    }

    private func isSameScope(_ lhs: String?, _ rhs: String?) -> Bool {
        lhs == rhs
    }

    private func hasVisibleSurface(key: String) -> Bool {
        // Pi/TUI widget and status keys are global identity. Scope metadata is
        // only a fallback for grouping related surfaces that use different keys.
        widgets.values.contains { widget in
            widget.key == key && !widget.lines.isEmpty
        } || nativeSurfaces.values.contains { nativeSurface in
            nativeSurface.key == key && nativeSurface.hasVisibleContent
        }
    }

    private func directlyAttachedStatus(key: String, extensionScopeId: String?) -> ExtensionStatusState? {
        guard hasVisibleSurface(key: key) else { return nil }
        return statuses.values.first { status in
            status.key == key
                && !status.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func scopedSingletonStatus(extensionScopeId: String?) -> ExtensionStatusState? {
        guard extensionScopeId != nil,
              visibleSurfaceCount(in: extensionScopeId) == 1,
              statusCount(in: extensionScopeId) == 1 else {
            return nil
        }
        return statuses.values.first { status in
            status.extensionScopeId == extensionScopeId
                && !status.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    func attachedStatus(for key: String, extensionScopeId: String?) -> ExtensionStatusState? {
        directlyAttachedStatus(key: key, extensionScopeId: extensionScopeId)
            ?? scopedSingletonStatus(extensionScopeId: extensionScopeId)
    }

    func attachedStatusText(for key: String, extensionScopeId: String?) -> String? {
        attachedStatus(for: key, extensionScopeId: extensionScopeId)?.text.trimmedNonEmpty
    }

    func displayTitle(for widget: ExtensionWidgetState) -> String? {
        guard let attachedStatus = attachedStatus(for: widget.key, extensionScopeId: widget.extensionScopeId),
              attachedStatus.key != widget.key else {
            return nil
        }
        return widget.extensionDisplayName?.trimmedNonEmpty
            ?? attachedStatus.extensionDisplayName?.trimmedNonEmpty
    }

    private func isAttachedStatus(_ status: ExtensionStatusState) -> Bool {
        if directlyAttachedStatus(key: status.key, extensionScopeId: status.extensionScopeId) != nil {
            return true
        }
        guard status.extensionScopeId != nil else { return false }
        return visibleSurfaceCount(in: status.extensionScopeId) == 1
            && statusCount(in: status.extensionScopeId) == 1
    }

    func standaloneStatusEntries() -> [(id: String, key: String, text: String)] {
        let candidates = statuses
            .filter { _, status in
                !isAttachedStatus(status)
                    && !status.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            .map { storageKey, status in
                (
                    id: storageKey,
                    key: status.key.trimmingCharacters(in: .whitespacesAndNewlines),
                    text: status.text.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
            .filter { !$0.key.isEmpty && !$0.text.isEmpty }
            .sorted { lhs, rhs in
                let keyOrder = lhs.key.localizedCaseInsensitiveCompare(rhs.key)
                if keyOrder != .orderedSame { return keyOrder == .orderedAscending }
                return lhs.id < rhs.id
            }

        var seen = Set<String>()
        return candidates.filter { status in
            let identity = "\(status.key.lowercased())\u{1f}\(status.text)"
            return seen.insert(identity).inserted
        }
    }

    func hasVisibleMetadata(in placement: ExtensionSurfacePlacementGroup) -> Bool {
        guard placement.showsChrome else { return false }
        let hasTitle = !(title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        return hasTitle || !standaloneStatusEntries().isEmpty
    }

    func hasVisibleContent(in placement: ExtensionSurfacePlacementGroup) -> Bool {
        hasVisibleMetadata(in: placement) || !widgetEntries(in: placement).isEmpty
    }
}

private struct ExtensionSurfaceMetadataCard: View {
    let title: String?
    let statuses: [(id: String, key: String, text: String)]

    private var trimmedTitle: String? {
        title?.trimmingCharacters(in: .whitespacesAndNewlines).trimmedNonEmpty
    }

    private var usesCompactStatusStrip: Bool {
        trimmedTitle == nil && statuses.count <= 3
    }

    var body: some View {
        Group {
            if usesCompactStatusStrip {
                compactStatusStrip
            } else {
                expandedMetadataRows
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .extensionGlassPanel(cornerRadius: 18)
    }

    private var compactStatusStrip: some View {
        HStack(spacing: 8) {
            ForEach(statuses, id: \.id) { status in
                HStack(spacing: 5) {
                    Text(status.key)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.themeComment)
                        .lineLimit(1)
                    Text(status.text)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.themeFg)
                        .lineLimit(1)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .extensionSubtleInset(cornerRadius: 11)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(status.key), \(status.text)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var expandedMetadataRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let trimmedTitle {
                Text(trimmedTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.themeComment)
            }

            ForEach(statuses, id: \.id) { status in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(status.key)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.themeComment)
                    Text(status.text)
                        .font(.caption)
                        .foregroundStyle(.themeFg)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(status.key), \(status.text)")
            }
        }
    }
}

private struct ExtensionWidgetCard: View {
    let widget: ExtensionWidgetState
    let statusText: String?
    let titleOverride: String?

    @State private var isExpanded = true
    @State private var isDetailPresented = false

    private var identifierSuffix: String {
        widget.key.extensionAccessibilityIdentifierComponent
    }

    private var titleText: String {
        if let titleOverride = titleOverride?.trimmingCharacters(in: .whitespacesAndNewlines), !titleOverride.isEmpty {
            return titleOverride
        }
        let trimmedKey = widget.key.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedKey.isEmpty ? "Extension widget" : trimmedKey
    }

    private var collapsedPreview: String? {
        widget.lines
            .map { ANSIParser.strip($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    private var headerText: ExtensionSurfaceHeaderText {
        ExtensionSurfaceHeaderText(title: titleText, statusText: statusText)
    }

    private var fullScreenContent: FullScreenCodeContent {
        .terminal(content: widget.lines.joined(separator: "\n"), command: nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(headerText.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.themeFg)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if let subtitle = headerText.subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.themeComment)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    } else if !headerText.didPromoteStatus, !isExpanded, let collapsedPreview {
                        Text(collapsedPreview)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.themeComment)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                ExtensionDisclosureChevron(isExpanded: isExpanded)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .gesture(activationGesture)
            .accessibilityIdentifier("extension-widget-\(identifierSuffix)-toggle")
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("\(isExpanded ? "Collapse" : "Expand") \(headerText.title) widget")
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint("Tap to expand. Double tap to open full screen.")
            .accessibilityAction {
                toggleExpanded()
            }
            .accessibilityAction(named: Text("Open Full Screen")) {
                openDetail()
            }

            if isExpanded {
                ExtensionWidgetLinesView(
                    lines: widget.lines,
                    scrollIdentifier: "extension-widget-\(identifierSuffix)-scroll",
                    onOpenFullScreen: openDetail
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity)
            }
        }
        .highPriorityGesture(
            TapGesture(count: 2).onEnded {
                if isExpanded {
                    openDetail()
                }
            }
        )
        .fullScreenViewer(
            isPresented: $isDetailPresented,
            content: fullScreenContent,
            sourceLabel: headerText.title
        )
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .extensionGlassPanel(cornerRadius: 18)
    }

    private var activationGesture: some Gesture {
        TapGesture(count: 2)
            .exclusively(before: TapGesture())
            .onEnded { value in
                switch value {
                case .first:
                    openDetail()
                case .second:
                    toggleExpanded()
                }
            }
    }

    private func toggleExpanded() {
        withAnimation(.easeOut(duration: 0.10)) {
            isExpanded.toggle()
        }
    }

    private func openDetail() {
        isDetailPresented = true
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
    case messageQueue(steeringCount: Int, followUpCount: Int)

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
        case .messageQueue(let steeringCount, let followUpCount):
            return "\(steeringCount) steering • \(followUpCount) follow-up"
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
        case .messageQueue(let steeringCount, let followUpCount):
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
            return "list.bullet"
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
            case .terminal(_, let lines):
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

                Image(systemName: isActive ? "chevron.down" : "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.themeComment)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(minHeight: 36)
            .background(
                Color.themeFg.opacity(isActive ? 0.1 : 0.045),
                in: Capsule()
            )
            .overlay {
                Capsule()
                    .stroke(isActive ? entry.stateTone.color.opacity(0.45) : Color.themeFg.opacity(0.08), lineWidth: 1)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("extension-strip-\(placement.accessibilityIdentifierComponent)-pill-\(entry.identifierSuffix)")
        .accessibilityLabel("\(isActive ? "Collapse" : "Expand") \(entry.title) \(entry.kindLabel)")
        .accessibilityValue(entry.subtitle ?? (isActive ? "Expanded" : "Collapsed"))
    }
}

private struct ExtensionSurfaceDrawer: View {
    let entry: ExtensionSurfaceStripEntry
    let placement: ExtensionSurfacePlacementGroup
    var messageQueue: MessageQueueSurfaceConfiguration?
    var onOpenURL: ((URL) -> Bool)?
    let onCollapse: () -> Void

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
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button(action: onCollapse) {
                    Image(systemName: "chevron.up")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.themeComment)
                        .frame(width: 32, height: 32)
                        .background(Color.themeFg.opacity(0.04), in: Circle())
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
            ExtensionNativeSurfaceExpandedViewport(
                surface: nativeSurface.surface,
                identifierSuffix: identifierSuffix,
                maxHeight: 260,
                onOpenFullScreen: { nativeDetailPresented = true },
                onOpenURL: onOpenURL
            )
        case .widget(let widget, _, _):
            ExtensionWidgetLinesView(
                lines: widget.lines,
                scrollIdentifier: "extension-strip-\(placement.accessibilityIdentifierComponent)-terminal-\(identifierSuffix)",
                onOpenFullScreen: { terminalDetailPresented = true }
            )
            .frame(maxWidth: .infinity, alignment: .leading)
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
            nativeDetailPresented = true
        case .widget:
            terminalDetailPresented = true
        case .title, .status, .messageQueue:
            break
        }
    }
}

struct ExtensionSurfacePanel: View {
    let surface: ExtensionSurfaceState
    let placement: ExtensionSurfacePlacementGroup
    var messageQueue: MessageQueueSurfaceConfiguration? = nil
    var onOpenURL: ((URL) -> Bool)? = nil
    var onExpandedEntryChange: ((Bool) -> Void)? = nil

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
            result.append(.messageQueue(
                steeringCount: messageQueue.queue.steering.count,
                followUpCount: messageQueue.queue.followUp.count
            ))
        }
        return result
    }

    private var activeEntry: ExtensionSurfaceStripEntry? {
        guard let expandedEntryID else { return nil }
        return stripEntries.first { $0.id == expandedEntryID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !stripEntries.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(stripEntries) { entry in
                            ExtensionSurfaceStripPill(
                                entry: entry,
                                isActive: activeEntry?.id == entry.id,
                                placement: placement,
                                onTap: { toggle(entry) }
                            )
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 7)
                }
                .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
                .accessibilityIdentifier("extension-strip-\(placement.accessibilityIdentifierComponent)-collapsed")
                .extensionStripGlassPanel(cornerRadius: 18)
            }

            if let activeEntry {
                ExtensionSurfaceDrawer(
                    entry: activeEntry,
                    placement: placement,
                    messageQueue: messageQueue,
                    onOpenURL: onOpenURL,
                    onCollapse: collapseActiveEntry
                )
                .id(activeEntry.id)
                .transition(.opacity)
            }
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
