import SwiftUI

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
        .background(Color.themeBg.opacity(0.55), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.themeComment.opacity(0.16), lineWidth: 1)
        }
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
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Text(titleText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.themeFg)

                    Spacer(minLength: 8)

                    if let summaryText {
                        Text(summaryText)
                            .font(.caption2)
                            .foregroundStyle(.themeComment)
                    }

                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.themeComment)
                        .accessibilityHidden(true)
                }
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
            .background(Color.themeBg.opacity(0.45), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
        HStack(spacing: 8) {
            if isIndeterminate {
                ProgressView()
                    .controlSize(.small)
            } else if let normalizedValue {
                ProgressView(value: normalizedValue)
                    .controlSize(.small)
            }

            if let trimmedLabel {
                Text(trimmedLabel)
                    .font(.caption)
                    .foregroundStyle(.themeFg)
            }
        }
        .frame(minHeight: trimmedLabel == nil ? 14 : 28, alignment: .leading)
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
        .background(Color.themeBg.opacity(0.55), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.themeComment.opacity(0.16), lineWidth: 1)
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

    var body: some View {
        let content = ExtensionNativeActivityRowContent(row: row, showsNavigationCue: linkedURL != nil)
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

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            stateMarker
                .frame(width: 14, height: 14)
                .padding(.top, 2)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.themeFg)
                    .lineLimit(2)
                    .truncationMode(.tail)

                if let subtitle = row.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.themeComment)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                if let detail = row.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.themeComment)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }

                if let progress = normalizedProgress {
                    ProgressView(value: progress)
                        .controlSize(.small)
                        .padding(.top, 2)
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
        .frame(minHeight: showsNavigationCue ? 44 : 30, alignment: .center)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
    }

    @ViewBuilder
    private var stateMarker: some View {
        switch row.state {
        case "running":
            Image(systemName: "bolt.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.themeBlue)
        case "success":
            Image(systemName: "checkmark.circle.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.themeGreen)
        case "warning":
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.themeOrange)
        case "error":
            Image(systemName: "xmark.circle.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.themeRed)
        case "inactive":
            Circle()
                .stroke(Color.themeComment.opacity(0.75), lineWidth: 1.2)
                .frame(width: 8, height: 8)
        default:
            Circle()
                .fill(Color.themeComment)
                .frame(width: 8, height: 8)
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

extension ExtensionSurfaceState {
    func hasVisibleContent(in placement: ExtensionSurfacePlacementGroup) -> Bool {
        let hasTitle = placement.showsChrome && !(title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let hasStatuses = placement.showsChrome && !statuses.isEmpty
        let hasWidgets = widgets.values.contains {
            placement.includes(widgetPlacement: $0.placement) && !$0.lines.isEmpty
        }
        let hasNativeSurfaces = nativeSurfaces.values.contains {
            placement.includes(widgetPlacement: $0.placement) && $0.hasVisibleContent
        }
        return hasTitle || hasStatuses || hasWidgets || hasNativeSurfaces
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

    private var sortedWidgets: [ExtensionWidgetState] {
        surface.widgets
            .values
            .filter { placement.includes(widgetPlacement: $0.placement) }
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
    }

    private var sortedNativeSurfaces: [ExtensionNativeSurfaceState] {
        surface.nativeSurfaces
            .values
            .filter { placement.includes(widgetPlacement: $0.placement) }
            .sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if placement.showsChrome,
               let title = surface.title,
               !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.themeComment)
            }

            if placement.showsChrome {
                ForEach(sortedStatuses, id: \.key) { status in
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

            ForEach(sortedNativeSurfaces) { nativeSurface in
                ExtensionNativeSurfaceView(surface: nativeSurface.surface, onOpenURL: onOpenURL)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            ForEach(sortedWidgets, id: \.key) { widget in
                if !widget.lines.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        if sortedWidgets.count > 1 {
                            Text(widget.key)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.themeComment)
                        }
                        ExtensionWidgetLinesView(lines: widget.lines)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.themeBgHighlight, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.themeComment.opacity(0.25), lineWidth: 1)
        }
    }
}

