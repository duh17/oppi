import SwiftUI

// MARK: - Todo Tool Output

struct TodoToolOutputView: View {
    let output: String

    /// Parse synchronously — todo JSON is tiny (<1KB typically) and async
    /// parsing breaks UIKit viewport sizing (the hosting view measures before
    /// SwiftUI runs `.task`, returning an inflated height).
    private var parsed: ParsedTodoOutput {
        TodoToolOutputParser.parse(output)
    }

    var body: some View {
        switch parsed {
        case .item(let item):
            TodoToolItemCard(todo: item)
        case .list(let list):
            TodoToolListCard(list: list)
        case .text(let text):
            Text(String(text.prefix(2000)))
                .font(.caption.monospaced())
                .foregroundStyle(.themeFg)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.themeBgDark)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

private enum ParsedTodoOutput: Sendable {
    case item(TodoToolItem)
    case list(TodoToolListPayload)
    case text(String)
}

private struct TodoToolItem: Decodable, Sendable {
    let id: String?
    let title: String?
    let tags: [String]?
    let status: String?
    let createdAt: String?
    let body: String?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case tags
        case status
        case createdAt = "created_at"
        case body
    }

    var looksLikeTodo: Bool {
        id != nil || title != nil || status != nil || createdAt != nil || body != nil || !(tags ?? []).isEmpty
    }

    var canonicalID: String? {
        guard let id, !id.isEmpty else { return nil }
        return id
    }

    var displayID: String { canonicalID ?? "TODO-unknown" }
    var normalizedTags: [String] { tags ?? [] }
}

private struct TodoToolListPayload: Decodable, Sendable {
    let assigned: [TodoToolItem]?
    let open: [TodoToolItem]?
    let closed: [TodoToolItem]?

    var hasSections: Bool {
        assigned != nil || open != nil || closed != nil
    }

    var assignedItems: [TodoToolItem] { assigned ?? [] }
    var openItems: [TodoToolItem] { open ?? [] }
    var closedItems: [TodoToolItem] { closed ?? [] }
}

private enum TodoToolOutputParser {
    static func parse(_ output: String) -> ParsedTodoOutput {
        guard let data = output.data(using: .utf8) else {
            return .text(output)
        }

        let decoder = JSONDecoder()

        if let list = try? decoder.decode(TodoToolListPayload.self, from: data), list.hasSections {
            return .list(list)
        }

        if let item = try? decoder.decode(TodoToolItem.self, from: data), item.looksLikeTodo {
            return .item(item)
        }

        return .text(output)
    }
}

private struct TodoToolItemCard: View {
    let todo: TodoToolItem

    private static let maxBodyChars = 8_000

    private var trimmedBody: String {
        (todo.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var bodyPreview: String {
        String(trimmedBody.prefix(Self.maxBodyChars))
    }

    private var isBodyTruncated: Bool {
        trimmedBody.count > Self.maxBodyChars
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                TodoIDLabel(id: todo.canonicalID, fallback: todo.displayID)

                if let status = todo.status, !status.isEmpty {
                    TodoStatusBadge(status: status)
                }

                Spacer()

                if let created = todo.createdAt, !created.isEmpty {
                    Text(created)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.themeComment)
                        .lineLimit(1)
                }
            }

            if let title = todo.title, !title.isEmpty {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.themeFg)
            }

            if !todo.normalizedTags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(todo.normalizedTags, id: \.self) { tag in
                            Text(tag)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.themeBlue)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.themeBgHighlight)
                                .clipShape(Capsule())
                        }
                    }
                }
            }

            if !bodyPreview.isEmpty {
                Divider().overlay(Color.themeComment.opacity(0.2))
                MarkdownText(bodyPreview)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isBodyTruncated {
                    Text("… body truncated")
                        .font(.caption2)
                        .foregroundStyle(.themeComment)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.themeBgDark)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.themeComment.opacity(0.25), lineWidth: 1)
        )
    }
}

private struct TodoToolListCard: View {
    let list: TodoToolListPayload

    private static let maxRowsPerSection = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            todoSection(title: "Assigned", items: list.assignedItems)
            todoSection(title: "Open", items: list.openItems)
            if !list.closedItems.isEmpty {
                todoSection(title: "Closed", items: list.closedItems)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.themeBgDark)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.themeComment.opacity(0.25), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func todoSection(title: String, items: [TodoToolItem]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.caption2.monospaced().bold())
                    .foregroundStyle(.themeComment)

                ForEach(Array(items.prefix(Self.maxRowsPerSection).enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        TodoIDLabel(id: item.canonicalID, fallback: item.displayID)
                        if let status = item.status, !status.isEmpty {
                            TodoStatusBadge(status: status)
                        }
                        if let title = item.title, !title.isEmpty {
                            Text(title)
                                .font(.caption)
                                .foregroundStyle(.themeFg)
                                .lineLimit(1)
                        }
                    }
                    .padding(.vertical, 1)
                }

                if items.count > Self.maxRowsPerSection {
                    Text("+\(items.count - Self.maxRowsPerSection) more")
                        .font(.caption2)
                        .foregroundStyle(.themeComment)
                }
            }
        }
    }
}

private struct TodoIDLabel: View {
    let id: String?
    let fallback: String

    private var display: String { id ?? fallback }

    private var textView: some View {
        Text(display)
            .font(.caption2.monospaced())
            .foregroundStyle(.themeCyan)
            .underline(id != nil, color: .themeCyan.opacity(0.45))
    }

    var body: some View {
        if let id, !id.isEmpty {
            Button {
                UIPasteboard.general.string = id
            } label: {
                textView
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("Copy", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = id
                }
                Button("Copy Todo Get Command", systemImage: "terminal") {
                    UIPasteboard.general.string = "todo get \(id)"
                }
            }
        } else {
            textView
        }
    }
}

private struct TodoStatusBadge: View {
    let status: String

    private var normalized: String { status.lowercased() }

    private var tint: Color {
        switch normalized {
        case "done", "closed": return .themeGreen
        case "in-progress", "in_progress", "inprogress": return .themeOrange
        case "open": return .themeBlue
        default: return .themeComment
        }
    }

    var body: some View {
        Text(status)
            .font(.caption2.monospaced().bold())
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.12))
            .clipShape(Capsule())
    }
}
