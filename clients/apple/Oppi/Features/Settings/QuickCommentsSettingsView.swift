import SwiftUI

/// Settings view for managing user-configured quick comment templates.
///
/// Shows the ordered list of templates with edit/delete/reorder support.
/// Tapping a template opens an editor sheet. "Add Quick Comment" creates a new one.
struct QuickCommentsSettingsView: View {
    @Environment(QuickCommentTemplateStore.self) private var store

    @State private var editingTemplate: QuickCommentTemplate?
    @State private var isAdding = false
    @State private var showResetConfirmation = false

    var body: some View {
        List {
            Section {
                ForEach(store.templates) { template in
                    templateRow(template)
                }
                .onDelete { offsets in
                    store.delete(at: offsets)
                }
                .onMove { source, destination in
                    store.move(from: source, to: destination)
                }
            } header: {
                Text("Templates")
            } footer: {
                Text("Quick comments appear after selecting text and choosing Comment.")
            }

            Section {
                Button {
                    let newTemplate = QuickCommentTemplate(
                        id: UUID(),
                        title: "",
                        systemImage: "text.bubble",
                        promptPrefix: "",
                        sortOrder: store.templates.count
                    )
                    editingTemplate = newTemplate
                    isAdding = true
                } label: {
                    Label("Add Quick Comment", systemImage: "plus")
                }

                Button(role: .destructive) {
                    showResetConfirmation = true
                } label: {
                    Label("Reset to Defaults", systemImage: "arrow.counterclockwise")
                }
            }
        }
        .themedListSurface()
        .navigationTitle("Quick Comments")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
            }
        }
        .sheet(item: $editingTemplate) { template in
            NavigationStack {
                QuickCommentEditorView(
                    template: template,
                    isNew: isAdding,
                    onSave: { saved in
                        if isAdding {
                            store.add(saved)
                        } else {
                            store.update(saved)
                        }
                        editingTemplate = nil
                        isAdding = false
                    },
                    onCancel: {
                        editingTemplate = nil
                        isAdding = false
                    }
                )
            }
            .presentationDetents([.medium, .large])
        }
        .confirmationDialog(
            "Reset quick comments to defaults?",
            isPresented: $showResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) {
                store.resetToDefaults()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func templateRow(_ template: QuickCommentTemplate) -> some View {
        Button {
            isAdding = false
            editingTemplate = template
        } label: {
            HStack(spacing: 10) {
                Image(systemName: template.systemImage)
                    .font(.appAction)
                    .foregroundStyle(.themeBlue)
                    .frame(width: 24, alignment: .center)

                VStack(alignment: .leading, spacing: 2) {
                    Text(template.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.themeFg)

                    Text(template.quickCommentText)
                        .font(.caption2)
                        .foregroundStyle(.themeComment)
                        .lineLimit(1)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.appChip)
                    .foregroundStyle(.themeComment.opacity(0.5))
            }
            .padding(.vertical, 2)
        }
    }
}

// MARK: - Editor

/// Form for creating or editing a single quick comment template.
struct QuickCommentEditorView: View {
    @State private var title: String
    @State private var systemImage: String
    @State private var promptPrefix: String

    private let templateId: UUID
    private let sortOrder: Int
    private let isNew: Bool
    private let onSave: (QuickCommentTemplate) -> Void
    private let onCancel: () -> Void

    init(
        template: QuickCommentTemplate,
        isNew: Bool,
        onSave: @escaping (QuickCommentTemplate) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _title = State(initialValue: template.title)
        _systemImage = State(initialValue: template.systemImage)
        _promptPrefix = State(initialValue: template.promptPrefix)
        self.templateId = template.id
        self.sortOrder = template.sortOrder
        self.isNew = isNew
        self.onSave = onSave
        self.onCancel = onCancel
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !promptPrefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Form {
            Section("Basics") {
                TextField("Title", text: $title)
                    .textInputAutocapitalization(.words)

                HStack {
                    Text("Icon")
                    Spacer()
                    SFSymbolPicker(selection: $systemImage)
                }
            }

            Section("Inserted Text") {
                TextField("Comment text (e.g. \"Fix this.\")", text: $promptPrefix)
                    .textInputAutocapitalization(.sentences)

                Text("Inserted into the comment composer when you tap the quick comment.")
                    .font(.caption)
                    .foregroundStyle(.themeComment)
            }

            Section {
                previewSection
            } header: {
                Text("Preview")
            }
        }
        .themedListSurface()
        .navigationTitle(isNew ? "New Quick Comment" : "Edit Quick Comment")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", action: onCancel)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    let template = QuickCommentTemplate(
                        id: templateId,
                        title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                        systemImage: systemImage,
                        promptPrefix: promptPrefix.trimmingCharacters(in: .whitespacesAndNewlines),
                        sortOrder: sortOrder
                    )
                    onSave(template)
                }
                .disabled(!canSave)
            }
        }
    }

    private var previewSection: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.appSectionHeader)
                .foregroundStyle(.themeBlue)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title.isEmpty ? "Untitled" : title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(title.isEmpty ? .themeComment : .themeFg)

                Text(promptPrefix.isEmpty ? "Comment text required" : promptPrefix)
                    .font(.caption2)
                    .foregroundStyle(.themeComment)
                    .lineLimit(2)
            }

            Spacer()
        }
    }
}

// MARK: - SF Symbol Picker

/// Compact SF Symbol picker with common coding and review icons.
struct SFSymbolPicker: View {
    @Binding var selection: String

    private static let symbols: [(String, String)] = [
        ("questionmark.bubble", "Explain"),
        ("play.circle", "Do"),
        ("wrench.and.screwdriver", "Fix"),
        ("arrow.triangle.branch", "Branch"),
        ("plus.bubble", "Add"),
        ("plus.message", "New"),
        ("sparkles", "Sparkle"),
        ("lightbulb", "Idea"),
        ("magnifyingglass", "Search"),
        ("doc.text", "Doc"),
        ("terminal", "Terminal"),
        ("checkmark.shield", "Check"),
        ("arrow.2.squarepath", "Convert"),
        ("text.badge.checkmark", "Review"),
        ("pencil.and.outline", "Edit"),
        ("scissors", "Cut"),
        ("eye", "View"),
        ("bolt", "Quick"),
        ("hammer", "Build"),
        ("ant", "Debug"),
    ]

    @State private var showPicker = false

    var body: some View {
        Button {
            showPicker = true
        } label: {
            Image(systemName: selection)
                .font(.appSectionHeader)
                .foregroundStyle(.themeBlue)
                .frame(width: 32, height: 32)
                .background(.themeComment.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
        }
        .popover(isPresented: $showPicker) {
            symbolGrid
                .presentationCompactAdaptation(.popover)
        }
    }

    private var symbolGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(44)), count: 5), spacing: 8) {
            ForEach(Self.symbols, id: \.0) { symbol, label in
                Button {
                    selection = symbol
                    showPicker = false
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: symbol)
                            .font(.appEmoji)
                            .frame(width: 36, height: 36)
                            .background(
                                selection == symbol
                                    ? Color.themeBlue.opacity(0.15)
                                    : Color.clear,
                                in: RoundedRectangle(cornerRadius: 6)
                            )
                        Text(label)
                            .font(.appEmojiCaption)
                            .foregroundStyle(.themeComment)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(selection == symbol ? .themeBlue : .themeFg)
            }
        }
        .padding(12)
    }
}
