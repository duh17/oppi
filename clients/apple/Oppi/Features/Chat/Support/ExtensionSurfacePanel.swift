import Foundation
import SwiftUI
import UIKit

private extension View {
    func extensionGlassPanel(cornerRadius: CGFloat = 18) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .glassEffect(.regular, in: shape)
            .overlay {
                shape.stroke(Color.themeFg.opacity(0.12), lineWidth: 0.5)
            }
            .shadow(color: Color.black.opacity(0.08), radius: 10, x: 0, y: 2)
    }

    func extensionGlassInset(cornerRadius: CGFloat = 12) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .glassEffect(.regular, in: shape)
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
        .extensionGlassInset(cornerRadius: 12)
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
                .transition(.opacity.combined(with: .move(edge: .top)))
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
        withAnimation(.easeInOut(duration: 0.16)) {
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
        let width = bounds.width > 0 ? bounds.width : UIScreen.main.bounds.width
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

                Button("Done") {
                    dismiss()
                }
                .font(.subheadline.weight(.semibold))
                .accessibilityIdentifier("extension-native-surface-\(identifierSuffix)-detail-done")
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

private struct ExtensionWidgetLineView: View {
    let line: String

    private var trimmedLine: String {
        line.trimmingCharacters(in: .whitespacesAndNewlines)
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
                Text(line)
                    .font(.caption2.monospaced())
                    .foregroundStyle(isActivity ? .themeComment : .themeFg)
                    .lineLimit(1)
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
        case .native(let nativeSurface): return "native:\(nativeSurface.identityKey)"
        case .widget(let widget): return "widget:\(widget.identityKey)"
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
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    private var headerText: ExtensionSurfaceHeaderText {
        ExtensionSurfaceHeaderText(title: titleText, statusText: statusText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    isExpanded.toggle()
                }
            } label: {
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
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("extension-widget-\(identifierSuffix)-toggle")
            .accessibilityLabel("\(isExpanded ? "Collapse" : "Expand") \(headerText.title) widget")
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

            if isExpanded {
                ExtensionWidgetLinesView(
                    lines: widget.lines,
                    scrollIdentifier: "extension-widget-\(identifierSuffix)-scroll"
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .extensionGlassPanel(cornerRadius: 18)
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

struct ExtensionSurfacePanel: View {
    let surface: ExtensionSurfaceState
    let placement: ExtensionSurfacePlacementGroup
    var onOpenURL: ((URL) -> Bool)? = nil

    private var sortedStatuses: [(id: String, key: String, text: String)] {
        surface.standaloneStatusEntries()
    }

    private var entries: [ExtensionSurfacePanelEntry] {
        surface.widgetEntries(in: placement)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if surface.hasVisibleMetadata(in: placement) {
                ExtensionSurfaceMetadataCard(
                    title: surface.title,
                    statuses: sortedStatuses
                )
            }

            ForEach(entries) { entry in
                switch entry {
                case .native(let nativeSurface):
                    ExtensionNativeSurfaceView(
                        surface: nativeSurface.surface,
                        statusText: surface.attachedStatusText(
                            for: nativeSurface.key,
                            extensionScopeId: nativeSurface.extensionScopeId
                        ),
                        onOpenURL: onOpenURL
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .extensionGlassPanel(cornerRadius: 18)
                case .widget(let widget):
                    ExtensionWidgetCard(
                        widget: widget,
                        statusText: surface.attachedStatusText(
                            for: widget.key,
                            extensionScopeId: widget.extensionScopeId
                        ),
                        titleOverride: surface.displayTitle(for: widget)
                    )
                }
            }
        }
    }
}
