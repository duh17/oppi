import SwiftUI

/// Muted, temporary chip for extension `ctx.ui.notify()`, above the composer.
struct ExtensionNotifyChip: View {
    let state: ExtensionNotifyChipStore.SessionState
    var onToggleExpanded: () -> Void
    var onDismiss: () -> Void
    var onOpenURL: ((URL) -> Bool)?

    var body: some View {
        if state.isExpanded {
            expandedCard
        } else {
            collapsedChip
        }
    }

    private var collapsedChip: some View {
        HStack {
            Spacer(minLength: 0)
            Button(action: onToggleExpanded) {
                HStack(spacing: 6) {
                    Image(systemName: iconName(for: state.newest.notifyType))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(iconColor(for: state.newest.notifyType))
                        .accessibilityHidden(true)

                    Text(state.newest.extensionDisplayName)
                        .font(.caption2)
                        .foregroundStyle(.themeFgDim)
                        .lineLimit(1)

                    if state.count > 1 {
                        Text("\(state.count)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.themeComment)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.themeFg.opacity(0.08), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(collapsedAccessibilityLabel)
            .accessibilityHint("Expands the notification")
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("chat.extensionNotify.chip")
            Spacer(minLength: 0)
        }
    }

    private var expandedCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Button(action: onToggleExpanded) {
                    HStack(spacing: 6) {
                        Image(systemName: iconName(for: state.newest.notifyType))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(iconColor(for: state.newest.notifyType))
                            .accessibilityHidden(true)

                        Text("From extension · \(state.newest.extensionDisplayName)")
                            .font(.caption)
                            .foregroundStyle(.themeFgDim)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(collapsedAccessibilityLabel)
                .accessibilityHint("Collapses the notification")
                .accessibilityIdentifier("chat.extensionNotify.chip")

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.themeFgDim)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
                .accessibilityIdentifier("chat.extensionNotify.dismiss")
            }

            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(state.entries.enumerated()), id: \.element.id) { index, entry in
                    expandedEntry(entry, showsName: showsPerEntryName && index > 0)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            .themeFg.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .accessibilityIdentifier("chat.extensionNotify.expanded")
    }

    @ViewBuilder
    private func expandedEntry(
        _ entry: ExtensionNotifyChipStore.Entry,
        showsName: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if showsName {
                Text("From extension · \(entry.extensionDisplayName)")
                    .font(.caption2)
                    .foregroundStyle(.themeFgDim)
            }
            ForEach(Self.parseLines(entry.message)) { line in
                if let url = line.url {
                    Button {
                        _ = onOpenURL?(url)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(line.label)
                                .font(.footnote)
                                .foregroundStyle(.themeComment)
                            Text(url.absoluteString)
                                .font(.footnote)
                                .foregroundStyle(.themeBlue)
                                .lineLimit(2)
                        }
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(line.text)
                        .font(.footnote)
                        .foregroundStyle(.themeFg)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("From extension · \(entry.extensionDisplayName). \(entry.message)")
    }

    private var showsPerEntryName: Bool {
        Set(state.entries.map(\.extensionDisplayName)).count > 1
    }

    private var collapsedAccessibilityLabel: String {
        let newest = state.newest
        let base = "Notification from \(newest.extensionDisplayName): \(newest.message)"
        if state.count > 1 {
            return "\(base). \(state.count) notifications"
        }
        return base
    }

    private func iconName(for notifyType: String?) -> String {
        switch notifyType {
        case "error":
            return "exclamationmark.circle.fill"
        case "warning":
            return "exclamationmark.triangle.fill"
        default:
            return "bell"
        }
    }

    private func iconColor(for notifyType: String?) -> ThemeShapeStyle {
        switch notifyType {
        case "error":
            return .themeRed
        case "warning":
            return .themeOrange
        default:
            return .themeFgDim
        }
    }

    fileprivate struct ParsedLine: Identifiable {
        let id: Int
        let text: String
        let label: String
        let url: URL?
    }

    fileprivate static func parseLines(_ message: String) -> [ParsedLine] {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        return message.components(separatedBy: .newlines).enumerated().compactMap { index, raw in
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }

            let range = NSRange(location: 0, length: trimmed.utf16.count)
            guard let match = detector?.firstMatch(in: trimmed, options: [], range: range),
                  let urlRange = Range(match.range, in: trimmed),
                  let url = URL(string: String(trimmed[urlRange])),
                  url.scheme?.hasPrefix("http") == true else {
                return ParsedLine(id: index, text: trimmed, label: trimmed, url: nil)
            }

            let prefix = String(trimmed[..<urlRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            let label = prefix.isEmpty ? "Link" : prefix
            return ParsedLine(id: index, text: trimmed, label: label, url: url)
        }
    }
}
