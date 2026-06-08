import SwiftUI

private extension View {
    func extensionGlassPanel(cornerRadius: CGFloat = 18) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .background {
                shape.fill(.regularMaterial)
                shape.fill(Color.themeBg.opacity(0.84))
                shape.fill(
                    LinearGradient(
                        colors: [
                            Color.themeFg.opacity(0.04),
                            Color.clear,
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            }
            .overlay {
                shape.stroke(
                    LinearGradient(
                        colors: [
                            Color.themeFg.opacity(0.18),
                            Color.themeComment.opacity(0.16),
                            Color.themeFg.opacity(0.08),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
            }
            .shadow(color: Color.black.opacity(0.22), radius: 18, x: 0, y: 10)
    }

    func extensionGlassInset(cornerRadius: CGFloat = 12) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .background {
                shape.fill(.thinMaterial)
                shape.fill(Color.themeBg.opacity(0.82))
            }
            .overlay {
                shape.stroke(
                    LinearGradient(
                        colors: [
                            Color.themeFg.opacity(0.10),
                            Color.themeComment.opacity(0.12),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
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

private struct ExtensionWidgetLinesView: View {
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                ExtensionWidgetLineView(line: line)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .extensionGlassInset(cornerRadius: 12)
    }
}

struct ExtensionNativeSurfaceView: View {
    let surface: ExtensionUINativeSurface
    var onOpenURL: ((URL) -> Bool)?

    @State private var isExpanded = true

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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Text(titleText)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.themeFg)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 8)

                    if let summaryText {
                        StatusPill(
                            text: summaryText,
                            systemImage: "bolt.fill",
                            tone: .working,
                            emphasis: .quiet,
                            size: .small
                        )
                    }

                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.themeComment)
                        .frame(width: 24, height: 24)
                        .background(Color.themeFg.opacity(0.06), in: Circle())
                        .accessibilityHidden(true)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(titleText)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint(isExpanded ? "Collapse extension surface" : "Expand extension surface")

            if isExpanded {
                if displayBlocks.isEmpty {
                    let fallbackLines = surface.fallbackDisplayLines
                    if !fallbackLines.isEmpty {
                        ExtensionWidgetLinesView(lines: fallbackLines)
                    }
                } else {
                    ForEach(Array(displayBlocks.enumerated()), id: \.offset) { _, block in
                        ExtensionNativeBlockView(block: block, onOpenURL: onOpenURL)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}

private struct ExtensionNativeBlockView: View {
    let block: ExtensionUINativeBlock
    var onOpenURL: ((URL) -> Bool)?

    var body: some View {
        switch block {
        case .text(_, let spans):
            ExtensionNativeTextSpansView(spans: spans, onOpenURL: onOpenURL)
        case .markdown(_, let markdown):
            Text(markdown)
                .font(.caption)
                .foregroundStyle(.themeFg)
                .fixedSize(horizontal: false, vertical: true)
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
                    ExtensionNativeBlockView(block: child, onOpenURL: onOpenURL)
                }
            }
            .padding(10)
            .extensionGlassInset(cornerRadius: 12)
        case .activityList(_, let rows):
            ExtensionNativeActivityListView(rows: rows, onOpenURL: onOpenURL)
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
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                ExtensionNativeTextSpansView(
                    spans: line,
                    font: .caption2.monospaced(),
                    onOpenURL: onOpenURL
                )
                .lineLimit(1)
                .truncationMode(.tail)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
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
    var onOpenURL: ((URL) -> Bool)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(rows) { row in
                ExtensionNativeActivityRowView(row: row, onOpenURL: onOpenURL)
            }
        }
    }
}

private struct ExtensionNativeActivityRowView: View {
    @Environment(\.openURL) private var openURL

    let row: ExtensionUIActivityRow
    var onOpenURL: ((URL) -> Bool)?

    @State private var isExpanded = false

    private var canExpandInline: Bool {
        guard linkedURL == nil else { return false }
        if row.title.count > 34 || row.title.contains("\n") { return true }
        if let subtitle = row.subtitle, subtitle.count > 32 || subtitle.contains("\n") { return true }
        if let detail = row.detail, detail.count > 44 || detail.contains("\n") { return true }
        return false
    }

    var body: some View {
        let content = ExtensionNativeActivityRowContent(
            row: row,
            showsNavigationCue: linkedURL != nil,
            isExpanded: isExpanded
        )
        if let url = linkedURL {
            Button {
                if onOpenURL?(url) != true {
                    openURL(url)
                }
            } label: {
                content
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the related session")
        } else if canExpandInline {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    isExpanded.toggle()
                }
            } label: {
                content
            }
            .buttonStyle(.plain)
            .accessibilityHint(isExpanded ? "Collapse task text" : "Show full task text")
        } else {
            content
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
}

private struct ExtensionNativeActivityRowContent: View {
    let row: ExtensionUIActivityRow
    let showsNavigationCue: Bool
    let isExpanded: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            stateMarker
                .frame(width: 22, height: 22)
                .padding(.top, 1)
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

            if showsNavigationCue {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.themeComment)
                    .padding(.top, 3)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .frame(minHeight: showsNavigationCue ? 44 : 34, alignment: .center)
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

    private var markerFillOpacity: Double {
        row.state == "inactive" ? 0.04 : 0.14
    }

    private var markerStrokeOpacity: Double {
        row.state == "inactive" ? 0.42 : 0.26
    }

    @ViewBuilder
    private var stateMarker: some View {
        ZStack {
            Circle()
                .fill(rowAccentColor.opacity(markerFillOpacity))
            Circle()
                .stroke(rowAccentColor.opacity(markerStrokeOpacity), lineWidth: 1)
            markerGlyph
        }
    }

    @ViewBuilder
    private var markerGlyph: some View {
        switch row.state {
        case "running":
            Image(systemName: "bolt.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(rowAccentColor)
        case "success":
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(rowAccentColor)
        case "warning":
            Image(systemName: "exclamationmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(rowAccentColor)
        case "error":
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(rowAccentColor)
        case "queued":
            Image(systemName: "clock.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(rowAccentColor)
        case "inactive":
            Circle()
                .stroke(rowAccentColor.opacity(0.80), lineWidth: 1.4)
                .frame(width: 9, height: 9)
        default:
            Circle()
                .fill(rowAccentColor)
                .frame(width: 7, height: 7)
        }
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
                    .truncationMode(.tail)
            } else {
                Text(line)
                    .font(.caption2.monospaced())
                    .foregroundStyle(isActivity ? .themeComment : .themeFg)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
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

    func hasVisibleMetadata(in placement: ExtensionSurfacePlacementGroup) -> Bool {
        guard placement.showsChrome else { return false }
        let hasTitle = !(title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        return hasTitle || !statuses.isEmpty
    }

    func hasVisibleContent(in placement: ExtensionSurfacePlacementGroup) -> Bool {
        hasVisibleMetadata(in: placement) || !widgetEntries(in: placement).isEmpty
    }
}

private struct ExtensionSurfaceMetadataCard: View {
    let title: String?
    let statuses: [(key: String, text: String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title,
               !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.themeComment)
            }

            ForEach(statuses, id: \.key) { status in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(status.key)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.themeComment)
                    Text(status.text)
                        .font(.caption)
                        .foregroundStyle(.themeFg)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .extensionGlassPanel(cornerRadius: 18)
    }
}

private struct ExtensionWidgetCard: View {
    let widget: ExtensionWidgetState
    let showsKey: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if showsKey {
                Text(widget.key)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.themeComment)
            }
            ExtensionWidgetLinesView(lines: widget.lines)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .extensionGlassPanel(cornerRadius: 18)
    }
}

struct ExtensionSurfacePanel: View {
    let surface: ExtensionSurfaceState
    let placement: ExtensionSurfacePlacementGroup
    var onOpenURL: ((URL) -> Bool)? = nil

    private var sortedStatuses: [(key: String, text: String)] {
        surface.statuses
            .map { (key: $0.key, text: $0.value) }
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
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
                    ExtensionNativeSurfaceView(surface: nativeSurface.surface, onOpenURL: onOpenURL)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .extensionGlassPanel(cornerRadius: 18)
                case .widget(let widget):
                    ExtensionWidgetCard(
                        widget: widget,
                        showsKey: entries.count > 1
                    )
                }
            }
        }
    }
}

