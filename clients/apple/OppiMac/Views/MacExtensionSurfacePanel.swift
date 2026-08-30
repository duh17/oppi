import SwiftUI

/// One expanded placement in the composer overlay. Height is capped; overflow
/// scrolls internally. Not an iOS pill strip / replaceable drawer.
enum MacExtensionSurfaceLayout {
    static let expandedMaxHeight: CGFloat = 260
}

/// Shared parser for `span.link` and `activityRow.link`. Real URLs only.
enum MacExtensionSurfaceLink {
    static func url(from raw: String?) -> URL? {
        guard let raw,
              let url = URL(string: raw),
              url.scheme?.isEmpty == false else {
            return nil
        }
        return url
    }
}

/// Generic Mac painter for Pi extension widgets. Layout comes from protocol
/// metadata (`placement`, presentation, block types, span roles, activity
/// state). Do not branch on tool, extension, status, widget, or display names.
struct MacExtensionSurfacePanel: View {
    let surface: ExtensionSurfaceState
    let placement: ExtensionSurfacePlacementGroup
    @Environment(\.openURL) private var openURL

    private var entries: [ExtensionSurfacePanelEntry] {
        surface.widgetEntries(in: placement)
    }

    var body: some View {
        MacExtensionBoundedSurface {
            VStack(alignment: .leading, spacing: 8) {
                if placement.showsChrome {
                    chrome
                }

                ForEach(entries) { entry in
                    switch entry {
                    case .native(let nativeSurface):
                        MacExtensionNativeSurfaceCard(
                            nativeSurface: nativeSurface,
                            statusText: surface.attachedStatusText(
                                for: nativeSurface.key,
                                extensionScopeId: nativeSurface.extensionScopeId
                            )
                        )
                    case .widget(let widget):
                        MacExtensionWidgetLinesCard(
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
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .environment(\.openURL, OpenURLAction { url in
            openURL(url)
            return .handled
        })
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(placement == .belowEditor
            ? "mac.extension.surface.below"
            : "mac.extension.surface.above")
    }

    @ViewBuilder
    private var chrome: some View {
        if let title = surface.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            Text(title)
                .font(.headline)
                .foregroundStyle(.themeFg)
                .textSelection(.enabled)
        }

        ForEach(surface.standaloneStatusEntries(), id: \.id) { status in
            VStack(alignment: .leading, spacing: 2) {
                Text(status.key)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.themeFg)
                Text(status.text)
                    .font(.caption)
                    .foregroundStyle(.themeComment)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .themedSurface(
                .elevatedPanel,
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
        }
    }
}

private struct MacExtensionSurfaceContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct MacExtensionBoundedSurface<Content: View>: View {
    let maxHeight: CGFloat
    let content: Content
    @State private var contentHeight: CGFloat = 0

    init(
        maxHeight: CGFloat = MacExtensionSurfaceLayout.expandedMaxHeight,
        @ViewBuilder content: () -> Content
    ) {
        self.maxHeight = maxHeight
        self.content = content()
    }

    var body: some View {
        let cappedHeight = contentHeight > 0 ? min(contentHeight, maxHeight) : maxHeight
        ScrollView(.vertical, showsIndicators: contentHeight > maxHeight) {
            content
                .fixedSize(horizontal: false, vertical: true)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: MacExtensionSurfaceContentHeightKey.self,
                            value: proxy.size.height
                        )
                    }
                }
        }
        .onPreferenceChange(MacExtensionSurfaceContentHeightKey.self) { contentHeight = $0 }
        .frame(maxWidth: .infinity, maxHeight: cappedHeight, alignment: .top)
        .scrollBounceBehavior(.basedOnSize)
        .accessibilityIdentifier("mac.extension.surface.scroll")
    }
}

private struct MacExtensionNativeSurfaceCard: View {
    let nativeSurface: ExtensionNativeSurfaceState
    let statusText: String?

    private var surface: ExtensionUINativeSurface { nativeSurface.surface }

    private var title: String {
        surface.presentation.title?.extensionSurfaceTrimmedNonEmpty
            ?? nativeSurface.key.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? "Extension"
    }

    private var subtitle: String? {
        statusText?.extensionSurfaceTrimmedNonEmpty
            ?? surface.presentation.subtitle?.extensionSurfaceTrimmedNonEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.themeFg)
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.themeComment)
            }

            let blocks = surface.nativeDisplayBlocks
            if blocks.isEmpty {
                MacExtensionWidgetLinesView(lines: surface.fallbackDisplayLines)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                        MacExtensionNativeBlockView(block: block)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .themedSurface(
            .elevatedPanel,
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .accessibilityIdentifier(
            "extension-native-surface-\(nativeSurface.key.extensionAccessibilityIdentifierComponent)"
        )
    }
}

private struct MacExtensionWidgetLinesCard: View {
    let widget: ExtensionWidgetState
    let statusText: String?
    let titleOverride: String?

    private var title: String {
        titleOverride?.extensionSurfaceTrimmedNonEmpty
            ?? widget.key.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? "Extension widget"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.themeFg)
            if let statusText, !statusText.isEmpty {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.themeComment)
            }
            MacExtensionWidgetLinesView(lines: widget.lines)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .themedSurface(
            .elevatedPanel,
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .accessibilityIdentifier(
            "extension-widget-\(widget.key.extensionAccessibilityIdentifierComponent)"
        )
    }
}

private struct MacExtensionWidgetLinesView: View {
    let lines: [String]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(ANSIParser.strip(line))
                        .font(Font(FontPreferenceStore.macCodeFont()))
                        .foregroundStyle(.themeFg)
                        .textSelection(.enabled)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("extension-widget-lines-scroll")
        .background(
            .themeFg.opacity(0.04),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.themeFg.opacity(0.08), lineWidth: 0.5)
        }
    }
}

private struct MacExtensionNativeBlockView: View {
    let block: ExtensionUINativeBlock

    var body: some View {
        switch block {
        case .text(_, let spans):
            MacExtensionNativeTextSpansView(spans: spans)
        case .markdown(_, let markdown):
            MacExtensionNativeMarkdownView(markdown: markdown)
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
                    MacExtensionNativeBlockView(block: child)
                }
            }
            .padding(10)
            .background(
                .themeFg.opacity(0.04),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
        case .activityList(_, let rows):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(rows) { row in
                    MacExtensionNativeActivityRowView(row: row)
                }
            }
        case .progress(let base, let label, let value, let indeterminate):
            MacExtensionNativeProgressBlockView(
                base: base,
                label: label,
                value: value,
                indeterminate: indeterminate
            )
        case .terminal(_, let lines):
            MacExtensionNativeTerminalLinesView(lines: lines)
        case .code(_, let language, let text):
            VStack(alignment: .leading, spacing: 4) {
                if let language, !language.isEmpty {
                    Text(language)
                        .font(.caption2)
                        .foregroundStyle(.themeComment)
                }
                MacExtensionWidgetLinesView(lines: text.components(separatedBy: .newlines))
            }
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

private struct MacExtensionNativeProgressBlockView: View {
    let base: ExtensionUIBlockBase
    let label: String?
    let value: Double?
    let indeterminate: Bool?

    private var trimmedLabel: String? {
        label.extensionSurfaceTrimmedNonEmpty
    }

    private var normalizedValue: Double? {
        guard let value, value.isFinite else { return nil }
        return min(max(value, 0), 1)
    }

    private var isIndeterminate: Bool {
        indeterminate == true || normalizedValue == nil
    }

    var body: some View {
        Group {
            if isIndeterminate {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    if let trimmedLabel {
                        Text(trimmedLabel)
                            .font(.caption)
                            .foregroundStyle(.themeFg)
                    }
                }
            } else if let normalizedValue {
                VStack(alignment: .leading, spacing: 6) {
                    if let trimmedLabel {
                        Text(trimmedLabel)
                            .font(.caption)
                            .foregroundStyle(.themeFg)
                    }
                    ProgressView(value: normalizedValue)
                        .tint(.themeFg)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(base.accessibility?.label.extensionSurfaceTrimmedNonEmpty ?? trimmedLabel ?? "Progress")
    }
}

private struct MacExtensionNativeMarkdownView: View {
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
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct MacExtensionNativeTextSpansView: View {
    let spans: [ExtensionUITextSpan]
    var font: Font = .caption
    @Environment(\.openURL) private var openURL

    var body: some View {
        Text(spans.macExtensionNativeAttributedString)
            .font(font)
            .foregroundStyle(.themeFg)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .environment(\.openURL, OpenURLAction { url in
                openURL(url)
                return .handled
            })
    }
}

private struct MacExtensionNativeTerminalLinesView: View {
    let lines: [[ExtensionUITextSpan]]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    MacExtensionNativeTextSpansView(
                        spans: line,
                        font: Font(FontPreferenceStore.macCodeFont())
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
        .background(
            .themeFg.opacity(0.04),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }
}

private struct MacExtensionNativeActivityRowView: View {
    let row: ExtensionUIActivityRow
    @Environment(\.openURL) private var openURL

    private var childRows: [ExtensionUIActivityRow] {
        row.children ?? []
    }

    private var linkedURL: URL? {
        MacExtensionSurfaceLink.url(from: row.link)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let url = linkedURL {
                Button {
                    openURL(url)
                } label: {
                    rowHeader(showsNavigationCue: true)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the linked URL")
            } else {
                rowHeader(showsNavigationCue: false)
            }

            if let progress = normalizedProgress {
                ProgressView(value: progress)
                    .tint(rowAccentColor)
            }

            if !childRows.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(childRows) { child in
                        MacExtensionNativeActivityRowView(row: child)
                    }
                }
                .padding(.leading, 16)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(
            .themeFg.opacity(rowHighlightOpacity),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.title)
        .accessibilityIdentifier("extension.native.activity.row.\(row.id)")
    }

    private func rowHeader(showsNavigationCue: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: markerSymbolName)
                .font(.system(size: 14, weight: row.state == "inactive" ? .regular : .semibold))
                .foregroundStyle(rowAccentColor)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.themeFg)
                if let subtitle = row.subtitle.extensionSurfaceTrimmedNonEmpty {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.themeComment)
                }
                if let detail = row.detail.extensionSurfaceTrimmedNonEmpty {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.themeFgDim)
                }
            }
            Spacer(minLength: 0)
            if showsNavigationCue {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.themeComment)
                    .padding(.top, 3)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
    }

    private var normalizedProgress: Double? {
        guard let progress = row.progress, progress.isFinite else { return nil }
        return min(max(progress, 0), 1)
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
}

private extension Array where Element == ExtensionUITextSpan {
    var macExtensionNativeAttributedString: AttributedString {
        var result = AttributedString()
        for span in self {
            result.append(span.macExtensionNativeAttributedString)
        }
        return result
    }
}

private extension ExtensionUITextSpan {
    var macExtensionNativeAttributedString: AttributedString {
        var result = AttributedString(text)
        let traits = Set((traits ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
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
        if let color = nativeRoleColor {
            result.foregroundColor = color
        }
        if role?.lowercased() == "code" || traits.contains("monospaced") {
            result.font = Font(FontPreferenceStore.macCodeFont())
        }
        if let url = MacExtensionSurfaceLink.url(from: link) {
            result.link = url
            result.underlineStyle = .single
            if nativeRoleColor == nil {
                result.foregroundColor = .themeCyan
            }
        }
        return result
    }

    var nativeRoleColor: Color? {
        switch role?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "primary": .themeFg
        case "secondary": .themeComment
        case "muted": .themeFgDim
        case "accent": .themeCyan
        case "success": .themeGreen
        case "warning": .themeOrange
        case "danger": .themeRed
        case "code": .themeYellow
        default: nil
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }

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
