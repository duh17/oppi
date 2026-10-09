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

            NativeSurfaceViewportScrollContainer(
                maxHeight: ExtensionNativeSurfaceLayout.expandedMaxHeight,
                accessibilityIdentifier: "chat.extensionNotify.list"
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(state.entries.enumerated()), id: \.element.id) { index, entry in
                        expandedEntry(entry, showsName: showsPerEntryName && index > 0)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
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
        let attributed = Self.attributedMessage(entry.message)
        let hasLinks = Self.containsHTTPLinks(attributed)
        let entryBody = VStack(alignment: .leading, spacing: 4) {
            if showsName {
                Text("From extension · \(entry.extensionDisplayName)")
                    .font(.caption2)
                    .foregroundStyle(.themeFgDim)
            }
            Text(attributed)
                .font(.footnote)
                .foregroundStyle(.themeFg)
                .fixedSize(horizontal: false, vertical: true)
                .environment(\.openURL, OpenURLAction { url in
                    Self.openHTTPURL(url, onOpenURL: onOpenURL)
                })
        }
        if hasLinks {
            entryBody.accessibilityElement(children: .contain)
        } else {
            entryBody
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    "From extension · \(entry.extensionDisplayName). \(entry.message)"
                )
        }
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

    static func attributedMessage(_ message: String) -> AttributedString {
        var attributed = AttributedString(message)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return attributed
        }
        let nsRange = NSRange(message.startIndex..., in: message)
        detector.enumerateMatches(in: message, options: [], range: nsRange) { match, _, _ in
            guard let match,
                  let stringRange = Range(match.range, in: message),
                  let url = URL(string: String(message[stringRange])),
                  Self.isHTTPURL(url),
                  let attributedRange = Range(stringRange, in: attributed)
            else { return }
            attributed[attributedRange].link = url
        }
        return attributed
    }

    static func containsHTTPLinks(_ attributed: AttributedString) -> Bool {
        attributed.runs.contains { run in
            guard let url = run.link else { return false }
            return isHTTPURL(url)
        }
    }

    private static func isHTTPURL(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        return scheme == "http" || scheme == "https"
    }

    private static func openHTTPURL(
        _ url: URL,
        onOpenURL: ((URL) -> Bool)?
    ) -> OpenURLAction.Result {
        guard isHTTPURL(url) else { return .discarded }
        return onOpenURL?(url) == true ? .handled : .discarded
    }
}
