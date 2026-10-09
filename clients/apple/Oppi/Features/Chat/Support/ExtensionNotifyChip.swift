import SwiftUI

/// Strip pill for extension `ctx.ui.notify()`, on the above-composer row.
struct ExtensionNotifyChip: View {
    let state: ExtensionNotifyChipStore.SessionState
    var onToggleExpanded: () -> Void

    var body: some View {
        Button(action: onToggleExpanded) {
            HStack(spacing: 7) {
                Image(systemName: ExtensionNotifyChipChrome.iconName(for: state.newest.notifyType))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(ExtensionNotifyChipChrome.iconColor(for: state.newest.notifyType))
                    .accessibilityHidden(true)

                Text(state.newest.extensionDisplayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.themeFg)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 180, alignment: .leading)

                if state.count > 1 {
                    Text("\(state.count)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.themeComment)
                        .lineLimit(1)
                }

                Image(systemName: state.isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.themeComment)
                    .accessibilityHidden(true)
            }
            .extensionStripPillSurface(
                isActive: state.isExpanded,
                activeStroke: ExtensionNotifyChipChrome.activeStroke(for: state.newest.notifyType)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(collapsedAccessibilityLabel)
        .accessibilityHint(state.isExpanded ? "Collapses the notification" : "Expands the notification")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("chat.extensionNotify.chip")
        .accessibilityValue(state.isExpanded ? "Expanded" : "Collapsed")
    }

    private var collapsedAccessibilityLabel: String {
        let newest = state.newest
        let base = "Notification from \(newest.extensionDisplayName): \(newest.message)"
        if state.count > 1 {
            return "\(base). \(state.count) notifications"
        }
        return base
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

    fileprivate static func isHTTPURL(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        return scheme == "http" || scheme == "https"
    }

    fileprivate static func openHTTPURL(
        _ url: URL,
        onOpenURL: ((URL) -> Bool)?
    ) -> OpenURLAction.Result {
        guard isHTTPURL(url) else { return .discarded }
        return onOpenURL?(url) == true ? .handled : .discarded
    }
}

/// Drawer under the above-composer strip for extension `ctx.ui.notify()`.
struct ExtensionNotifyDrawer: View {
    let state: ExtensionNotifyChipStore.SessionState
    var onCollapse: () -> Void
    var onDismiss: () -> Void
    var onOpenURL: ((URL) -> Bool)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("From extension · \(state.newest.extensionDisplayName)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.themeFg)
                        .lineLimit(1)
                    if state.count > 1 {
                        Text("\(state.count) notifications")
                            .font(.caption)
                            .foregroundStyle(.themeComment)
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
                .accessibilityLabel("Collapse notification")

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.themeFgDim)
                        .frame(width: 32, height: 32)
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
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .extensionGlassPanel(cornerRadius: 18)
        .accessibilityIdentifier("chat.extensionNotify.expanded")
    }

    @ViewBuilder
    private func expandedEntry(
        _ entry: ExtensionNotifyChipStore.Entry,
        showsName: Bool
    ) -> some View {
        let attributed = ExtensionNotifyChip.attributedMessage(entry.message)
        let hasLinks = ExtensionNotifyChip.containsHTTPLinks(attributed)
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
                    ExtensionNotifyChip.openHTTPURL(url, onOpenURL: onOpenURL)
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
}

private enum ExtensionNotifyChipChrome {
    static func iconName(for notifyType: String?) -> String {
        switch notifyType {
        case "error":
            return "exclamationmark.circle.fill"
        case "warning":
            return "exclamationmark.triangle.fill"
        default:
            return "bell"
        }
    }

    static func iconColor(for notifyType: String?) -> ThemeShapeStyle {
        switch notifyType {
        case "error":
            return .themeRed
        case "warning":
            return .themeOrange
        default:
            return .themeCyan
        }
    }

    static func activeStroke(for notifyType: String?) -> Color {
        switch notifyType {
        case "error":
            return .themeRed
        case "warning":
            return .themeOrange
        default:
            return .themeCyan
        }
    }
}
