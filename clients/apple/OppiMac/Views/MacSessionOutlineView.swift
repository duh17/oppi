import SwiftUI

/// Session outline popover. The timeline stays visible behind this chrome.
///
/// Parse lives in OppiCore (`SessionOutlineSnapshot` + projection). This view
/// only paints and asks the session store to jump.
struct MacSessionOutlineView: View {
    let store: MacSessionTraceStore
    var onJump: () -> Void = {}

    @State private var query = ""
    @State private var filter: SessionOutlineFilter = .all

    private var displayedEntries: [SessionOutlineEntrySnapshot] {
        SessionOutlineProjection.displayedEntries(
            store.sessionOutline?.entries ?? [],
            filter: filter,
            query: query
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            filterBar
            Divider()
            outlineList
        }
        .frame(minWidth: 360, idealWidth: 380, minHeight: 420)
        .task {
            await store.loadSessionOutlineFromLocalConfig()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Session Outline")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Session Outline")
                .font(.headline)
            Spacer()
            if store.isLoadingSessionOutline {
                ProgressView()
                    .controlSize(.small)
            }
            Text("\(displayedEntries.count) items")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search session timeline", text: $query)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("mac.session.outline.search")

            Picker("Filter", selection: $filter) {
                ForEach(SessionOutlineFilter.allCases, id: \.self) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("mac.session.outline.filter")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var outlineList: some View {
        if let error = store.sessionOutlineError,
           store.sessionOutline == nil,
           !error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ContentUnavailableView(
                "Outline unavailable",
                systemImage: "list.bullet",
                description: Text(error)
            )
        } else if store.isLoadingSessionOutline, store.sessionOutline == nil {
            ProgressView("Loading outline…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if displayedEntries.isEmpty {
            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                ContentUnavailableView(
                    "No outline entries",
                    systemImage: "list.bullet",
                    description: Text("This session has no timeline entries yet.")
                )
            }
        } else {
            List(displayedEntries) { entry in
                Button {
                    Task {
                        await store.jumpToOutlineEntry(entry.id)
                        onJump()
                    }
                } label: {
                    MacSessionOutlineRow(entry: entry)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("mac.session.outline.row")
            }
            .listStyle(.plain)
        }
    }
}

private struct MacSessionOutlineRow: View {
    let entry: SessionOutlineEntrySnapshot
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: iconName)
                .font(.caption)
                .foregroundStyle(iconColor)
                .frame(width: 16)
            Text(entry.summary)
                .font(.caption)
                .foregroundStyle(textColor)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let timestamp {
                Text(timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var timestamp: Date? {
        guard !entry.timestamp.isEmpty else { return nil }
        return FastISO8601Parser.parse(entry.timestamp, fallback: Self.outlineDateFormatter)
    }

    nonisolated(unsafe) private static let outlineDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private var iconName: String {
        switch entry.kind {
        case "user":
            "person.fill"
        case "assistant":
            "cpu"
        case "thinking":
            "sparkle"
        case "tool":
            ToolCallFormatting.sfSymbolName(for: entry.tool ?? "") ?? "wrench"
        case "compaction":
            "arrow.trianglehead.2.clockwise.rotate.90"
        case "error":
            "exclamationmark.triangle"
        default:
            "info.circle"
        }
    }

    private var iconColor: Color {
        if entry.isError == true {
            return theme.accent.red
        }
        switch entry.kind {
        case "user":
            return theme.accent.blue
        case "assistant", "thinking":
            return theme.accent.purple
        case "tool":
            return theme.accent.cyan
        case "compaction":
            return theme.accent.orange
        case "error":
            return theme.accent.red
        default:
            return theme.text.tertiary
        }
    }

    private var textColor: Color {
        switch entry.kind {
        case "user":
            theme.text.primary
        case "assistant", "tool":
            theme.text.secondary
        default:
            theme.text.tertiary
        }
    }
}
