import SwiftUI

/// Settings view for managing user-configured π quick actions.
///
/// Shows the ordered list of actions with edit/delete/reorder support.
/// Tapping an action opens an editor sheet. "Add Action" creates a new one.
struct PiActionsSettingsView: View {
    @Environment(PiQuickActionStore.self) private var store

    @State private var editingAction: PiQuickAction?
    @State private var isAdding = false
    @State private var showResetConfirmation = false

    var body: some View {
        List {
            Section {
                ForEach(store.actions) { action in
                    actionRow(action)
                }
                .onDelete { offsets in
                    store.delete(at: offsets)
                }
                .onMove { source, destination in
                    store.move(from: source, to: destination)
                }
            } header: {
                Text("Actions appear in the π text selection menu")
            }

            Section {
                Button {
                    let newAction = PiQuickAction(
                        id: UUID(),
                        title: "",
                        systemImage: "sparkles",
                        promptPrefix: "",
                        behavior: .currentSession,
                        sortOrder: store.actions.count
                    )
                    editingAction = newAction
                    isAdding = true
                } label: {
                    Label("Add Action", systemImage: "plus")
                }

                Button(role: .destructive) {
                    showResetConfirmation = true
                } label: {
                    Label("Reset to Defaults", systemImage: "arrow.counterclockwise")
                }
            }
        }
        .themedListSurface()
        .navigationTitle("π Actions")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
            }
        }
        .sheet(item: $editingAction) { action in
            NavigationStack {
                PiActionEditorView(
                    action: action,
                    isNew: isAdding,
                    onSave: { saved in
                        if isAdding {
                            store.add(saved)
                        } else {
                            store.update(saved)
                        }
                        editingAction = nil
                        isAdding = false
                    },
                    onCancel: {
                        editingAction = nil
                        isAdding = false
                    }
                )
            }
            .presentationDetents([.medium, .large])
        }
        .confirmationDialog(
            "Reset all π actions to defaults?",
            isPresented: $showResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) {
                store.resetToDefaults()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func actionRow(_ action: PiQuickAction) -> some View {
        Button {
            isAdding = false
            editingAction = action
        } label: {
            HStack(spacing: 10) {
                Image(systemName: action.systemImage)
                    .font(.appAction)
                    .foregroundStyle(.themeBlue)
                    .frame(width: 24, alignment: .center)

                VStack(alignment: .leading, spacing: 2) {
                    Text(action.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.themeFg)

                    HStack(spacing: 6) {
                        Text(action.behavior == .newSession ? "New session" : "Current session")
                            .font(.caption2)
                            .foregroundStyle(.themeComment)

                        if !action.isRawInsert {
                            Text(action.promptPrefix)
                                .font(.caption2)
                                .foregroundStyle(.themeComment)
                                .lineLimit(1)
                        }
                    }
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

/// Form for creating or editing a single π quick action.
struct PiActionEditorView: View {
    @State private var title: String
    @State private var systemImage: String
    @State private var promptPrefix: String
    @State private var behavior: PiQuickActionBehavior

    private let actionId: UUID
    private let sortOrder: Int
    private let isNew: Bool
    private let onSave: (PiQuickAction) -> Void
    private let onCancel: () -> Void

    init(
        action: PiQuickAction,
        isNew: Bool,
        onSave: @escaping (PiQuickAction) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _title = State(initialValue: action.title)
        _systemImage = State(initialValue: action.systemImage)
        _promptPrefix = State(initialValue: action.promptPrefix)
        _behavior = State(initialValue: action.behavior)
        self.actionId = action.id
        self.sortOrder = action.sortOrder
        self.isNew = isNew
        self.onSave = onSave
        self.onCancel = onCancel
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

            Section("Prompt") {
                TextField("Prompt prefix (e.g. \"Explain this:\")", text: $promptPrefix)
                    .textInputAutocapitalization(.never)

                if promptPrefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("No prefix — selected text will be inserted as-is")
                        .font(.caption)
                        .foregroundStyle(.themeComment)
                }
            }

            Section("Behavior") {
                Picker("When triggered", selection: $behavior) {
                    Text("Append to current session").tag(PiQuickActionBehavior.currentSession)
                    Text("Start new session").tag(PiQuickActionBehavior.newSession)
                }
                .pickerStyle(.menu)
            }

            Section {
                previewSection
            } header: {
                Text("Preview")
            }
        }
        .themedListSurface()
        .navigationTitle(isNew ? "New Action" : "Edit Action")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", action: onCancel)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    let action = PiQuickAction(
                        id: actionId,
                        title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                        systemImage: systemImage,
                        promptPrefix: promptPrefix.trimmingCharacters(in: .whitespacesAndNewlines),
                        behavior: behavior,
                        sortOrder: sortOrder
                    )
                    onSave(action)
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

                if !promptPrefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("\"\(promptPrefix)\" + selected text")
                        .font(.caption2)
                        .foregroundStyle(.themeComment)
                } else {
                    Text("selected text only")
                        .font(.caption2)
                        .foregroundStyle(.themeComment)
                }
            }

            Spacer()

            if behavior == .newSession {
                Image(systemName: "plus.message")
                    .font(.caption)
                    .foregroundStyle(.themeGreen)
            }
        }
    }
}

// MARK: - SF Symbol Picker

/// Compact SF Symbol picker with common coding/action icons.
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
