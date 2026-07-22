import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Purpose and state

enum IconPickerMedia: Hashable, Sendable {
    case emoji
    case genmoji
    case symbol
}

enum IconPickerPurpose: Sendable {
    case assistant
    case agent
    case workspace

    var allowedMedia: Set<IconPickerMedia> {
        switch self {
        case .assistant:
            return [.emoji, .genmoji]
        case .agent, .workspace:
            return [.emoji, .genmoji, .symbol]
        }
    }

    var title: String {
        switch self {
        case .assistant: return "Assistant Avatar"
        case .agent: return "Agent Icon"
        case .workspace: return "Workspace Icon"
        }
    }

    var symbolSectionTitle: String {
        switch self {
        case .assistant: return ""
        case .agent: return "Agent Symbols"
        case .workspace: return "Workspace Symbols"
        }
    }
}

enum IconPickerDraft<Value: Equatable & Sendable>: Equatable, Sendable {
    case value(Value)
    case genmoji(data: Data, contentDescription: String)
}

enum IconPickerCustomChoice: Equatable, Sendable {
    case emoji(String)
    case genmoji(String)

    var accessibilityDescription: String {
        switch self {
        case .emoji(let value): return "Emoji \(value)"
        case .genmoji(let contentDescription): return "Genmoji \(contentDescription)"
        }
    }
}

@MainActor @Observable
final class IconPickerModel<Value: Equatable & Sendable> {
    let purpose: IconPickerPurpose
    let defaultValue: Value
    private let customChoice: (Value) -> IconPickerCustomChoice?
    private let valueValidation: (Value) -> String?
    private(set) var savedValue: Value
    private(set) var draft: IconPickerDraft<Value>
    private(set) var customInputText: String
    private(set) var selectedCustomChoice: IconPickerCustomChoice?
    private(set) var validationMessage: String?
    private(set) var errorMessage: String?
    private(set) var isSaving = false

    init(
        purpose: IconPickerPurpose,
        savedValue: Value,
        defaultValue: Value,
        customChoice: @escaping (Value) -> IconPickerCustomChoice? = { _ in nil },
        valueValidation: @escaping (Value) -> String? = { _ in nil }
    ) {
        self.purpose = purpose
        self.savedValue = savedValue
        self.defaultValue = defaultValue
        self.customChoice = customChoice
        self.valueValidation = valueValidation
        draft = .value(savedValue)
        let initialCustomChoice = customChoice(savedValue)
        selectedCustomChoice = initialCustomChoice
        if case .emoji(let emoji)? = initialCustomChoice {
            customInputText = emoji
        } else {
            customInputText = ""
        }
    }

    var valueDraft: Value? {
        guard case .value(let value) = draft else { return nil }
        return value
    }

    var hasChanges: Bool {
        draft != .value(savedValue)
    }

    var canSave: Bool {
        hasChanges && validationMessage == nil && !isSaving
    }

    func selectDefault() {
        selectValue(defaultValue)
    }

    func selectValue(_ value: Value) {
        draft = .value(value)
        selectedCustomChoice = customChoice(value)
        if case .emoji(let emoji)? = selectedCustomChoice {
            customInputText = emoji
        } else {
            customInputText = ""
        }
        validationMessage = valueValidation(value)
        errorMessage = nil
    }

    @discardableResult
    func selectEmoji(_ rawValue: String, transform: (String) -> Value) -> Bool {
        guard purpose.allowedMedia.contains(.emoji) else { return false }
        customInputText = rawValue
        switch AgentIconValue.classify(rawValue) {
        case .emoji(let emoji):
            draft = .value(transform(emoji))
            customInputText = emoji
            selectedCustomChoice = .emoji(emoji)
            clearFeedback()
            return true
        case .symbolCandidate, .invalid:
            selectedCustomChoice = nil
            validationMessage = "Enter exactly one Unicode emoji."
            errorMessage = nil
            return false
        }
    }

    @discardableResult
    func selectGenmoji(data: Data, contentDescription: String) -> Bool {
        guard purpose.allowedMedia.contains(.genmoji) else { return false }
        let description = contentDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !data.isEmpty, !description.isEmpty, description.unicodeScalars.count <= 256 else {
            selectedCustomChoice = nil
            validationMessage = "Choose a Genmoji with a description."
            errorMessage = nil
            return false
        }
        draft = .genmoji(data: data, contentDescription: description)
        customInputText = ""
        selectedCustomChoice = .genmoji(description)
        clearFeedback()
        return true
    }

    func save(
        prepareGenmoji: (Data, String) async throws -> Value,
        commit: (Value) async throws -> Void
    ) async -> Bool {
        guard hasChanges, !isSaving else { return false }
        if case .value(let value) = draft,
           let validationMessage = valueValidation(value) {
            self.validationMessage = validationMessage
            errorMessage = nil
            return false
        }
        guard validationMessage == nil else { return false }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        do {
            let value: Value
            switch draft {
            case .value(let selectedValue):
                value = selectedValue
            case .genmoji(let data, let contentDescription):
                value = try await prepareGenmoji(data, contentDescription)
                // Keep the uploaded reference if persistence fails. Retry should
                // commit the same asset instead of uploading duplicate bytes.
                draft = .value(value)
            }

            try await commit(value)
            savedValue = value
            draft = .value(value)
            selectedCustomChoice = customChoice(value) ?? selectedCustomChoice
            if case .emoji(let emoji)? = selectedCustomChoice {
                customInputText = emoji
            } else {
                customInputText = ""
            }
            return true
        } catch {
            errorMessage = "Couldn’t save. \(error.localizedDescription)"
            return false
        }
    }

    private func clearFeedback() {
        validationMessage = nil
        errorMessage = nil
    }
}

// MARK: - Option metadata

struct IconPickerOption<Value: Equatable & Sendable>: Identifiable {
    let id: String
    let label: String
    let detail: String?
    let value: Value
}

struct IconSymbolOption: Identifiable, Equatable {
    let symbolName: String
    let label: String

    var id: String { symbolName }
}

enum IconSymbolCatalog {
    static let options: [IconSymbolOption] = [
        .init(symbolName: "folder", label: "Folder"),
        .init(symbolName: "folder.fill", label: "Folder Filled"),
        .init(symbolName: "square.grid.2x2", label: "Workspace"),
        .init(symbolName: "rectangle.3.group", label: "Project"),
        .init(symbolName: "terminal", label: "Terminal"),
        .init(symbolName: "chevron.left.forwardslash.chevron.right", label: "Code"),
        .init(symbolName: "curlybraces", label: "Braces"),
        .init(symbolName: "command", label: "Command"),
        .init(symbolName: "hammer", label: "Build"),
        .init(symbolName: "wrench.and.screwdriver", label: "Tools"),
        .init(symbolName: "ant", label: "Debug"),
        .init(symbolName: "ladybug", label: "Bug"),
        .init(symbolName: "shippingbox", label: "Package"),
        .init(symbolName: "cube", label: "Module"),
        .init(symbolName: "server.rack", label: "Server"),
        .init(symbolName: "externaldrive", label: "Storage"),
        .init(symbolName: "cloud", label: "Cloud"),
        .init(symbolName: "network", label: "Network"),
        .init(symbolName: "globe", label: "Web"),
        .init(symbolName: "arrow.triangle.branch", label: "Branch"),
        .init(symbolName: "point.3.connected.trianglepath.dotted", label: "Graph"),
        .init(symbolName: "doc.text", label: "Docs"),
        .init(symbolName: "book.closed", label: "Book"),
        .init(symbolName: "books.vertical", label: "Research"),
        .init(symbolName: "text.page", label: "Text"),
        .init(symbolName: "checklist", label: "Checklist"),
        .init(symbolName: "checkmark.shield", label: "Review"),
        .init(symbolName: "tray.full", label: "Archive"),
        .init(symbolName: "brain", label: "AI"),
        .init(symbolName: "brain.head.profile", label: "Thinking"),
        .init(symbolName: "sparkles", label: "Sparkles"),
        .init(symbolName: "magnifyingglass", label: "Search"),
        .init(symbolName: "lightbulb", label: "Idea"),
        .init(symbolName: "bolt", label: "Fast"),
        .init(symbolName: "flame", label: "Hot"),
        .init(symbolName: "star", label: "Favorite"),
        .init(symbolName: "heart", label: "Heart"),
        .init(symbolName: "flag", label: "Flag"),
        .init(symbolName: "tag", label: "Tag"),
        .init(symbolName: "lock", label: "Secure"),
        .init(symbolName: "shield", label: "Shield"),
        .init(symbolName: "person.2", label: "Team"),
        .init(symbolName: "paintbrush", label: "Design"),
        .init(symbolName: "photo", label: "Media"),
        .init(symbolName: "music.note", label: "Audio"),
        .init(symbolName: "gamecontroller", label: "Game"),
        .init(symbolName: "graduationcap", label: "Learning"),
        .init(symbolName: "leaf", label: "Nature"),
        .init(symbolName: "cart", label: "Shop"),
    ]

    static func isAvailable(_ symbolName: String) -> Bool {
        UIImage(systemName: symbolName) != nil
    }

    static func availableOptions(
        matching query: String,
        isAvailable: (String) -> Bool = IconSymbolCatalog.isAvailable
    ) -> [IconSymbolOption] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return options.filter {
            isAvailable($0.symbolName)
                && (trimmed.isEmpty
                    || $0.label.localizedCaseInsensitiveContains(trimmed)
                    || $0.symbolName.localizedCaseInsensitiveContains(trimmed))
        }
    }

    static func label(for symbolName: String) -> String? {
        options.first { $0.symbolName == symbolName }?.label
    }
}

// MARK: - Shared shell

/// A UIKit-backed field keeps the actual editable control—not just its SwiftUI
/// row—at the 44pt minimum hit target required by the icon picker.
@MainActor
private struct SymbolSearchField: UIViewRepresentable {
    @Binding var text: String
    let onTextChanged: (String) -> Void
    let onSubmit: (String) -> Void

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.placeholder = "Search symbols"
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.clearButtonMode = .whileEditing
        field.borderStyle = .roundedRect
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.textChanged), for: .editingChanged)
        field.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        field.accessibilityIdentifier = "symbolSearch"
        field.accessibilityLabel = "Search SF Symbols"
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self
        guard field.text != text else { return }
        field.text = text
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    @MainActor
    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: SymbolSearchField

        init(parent: SymbolSearchField) {
            self.parent = parent
        }

        @objc func textChanged(_ field: UITextField) {
            let currentText = field.text ?? ""
            parent.text = currentText
            parent.onTextChanged(currentText)
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            let submittedText = textField.text ?? ""
            parent.text = submittedText
            parent.onSubmit(submittedText)
            textField.resignFirstResponder()
            return true
        }
    }
}

struct UnifiedIconPickerView<Value: Equatable & Sendable>: View {
    typealias ValuePreview = (Value, CGFloat) -> AnyView
    typealias GenmojiPreview = (Data, String, CGFloat) -> AnyView

    @Environment(\.dismiss) private var dismiss
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    let purpose: IconPickerPurpose
    let builtinOptions: [IconPickerOption<Value>]
    let symbols: [IconSymbolOption]
    let makeEmoji: (String) -> Value
    let makeSymbol: ((String) -> Value)?
    let symbolName: ((Value) -> String?)?
    let symbolAvailability: (String) -> Bool
    let customChoice: (Value) -> IconPickerCustomChoice?
    let preview: ValuePreview
    let genmojiPreview: GenmojiPreview
    let prepareGenmoji: (Data, String) async throws -> Value
    let commit: (Value) async throws -> Void
    let accessibilityPrefix: String

    @State private var model: IconPickerModel<Value>
    @State private var symbolSearch = ""
    @State private var submittedSymbolSearch = ""
    @State private var symbolResultGeneration = 0
    @State private var glyphInputFocusRequest = 0
    @State private var draftGenmojiImage: UIImage?
    @AccessibilityFocusState private var errorFocused: Bool

    init(
        purpose: IconPickerPurpose,
        savedValue: Value,
        defaultValue: Value,
        builtinOptions: [IconPickerOption<Value>] = [],
        symbols: [IconSymbolOption] = IconSymbolCatalog.options,
        makeEmoji: @escaping (String) -> Value,
        makeSymbol: ((String) -> Value)?,
        symbolName: ((Value) -> String?)? = nil,
        symbolAvailability: @escaping (String) -> Bool = IconSymbolCatalog.isAvailable,
        customChoice: @escaping (Value) -> IconPickerCustomChoice? = { _ in nil },
        preview: @escaping ValuePreview,
        genmojiPreview: @escaping GenmojiPreview,
        prepareGenmoji: @escaping (Data, String) async throws -> Value,
        commit: @escaping (Value) async throws -> Void,
        accessibilityPrefix: String
    ) {
        self.purpose = purpose
        self.builtinOptions = builtinOptions
        self.symbols = symbols
        self.makeEmoji = makeEmoji
        self.makeSymbol = makeSymbol
        self.symbolName = symbolName
        self.symbolAvailability = symbolAvailability
        self.customChoice = customChoice
        self.preview = preview
        self.genmojiPreview = genmojiPreview
        self.prepareGenmoji = prepareGenmoji
        self.commit = commit
        self.accessibilityPrefix = accessibilityPrefix
        _model = State(initialValue: IconPickerModel(
            purpose: purpose,
            savedValue: savedValue,
            defaultValue: defaultValue,
            customChoice: customChoice,
            valueValidation: { value in
                guard let symbolName,
                      let name = symbolName(value),
                      !symbolAvailability(name) else {
                    return nil
                }
                return "The selected SF Symbol is unavailable on this device."
            }
        ))
    }

    private var filteredSymbols: [IconSymbolOption] {
        let query = submittedSymbolSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        return symbols.filter {
            symbolAvailability($0.symbolName)
                && (query.isEmpty
                    || $0.label.localizedCaseInsensitiveContains(query)
                    || $0.symbolName.localizedCaseInsensitiveContains(query))
        }
    }

    private var hasSubmittedSymbolSearch: Bool {
        !submittedSymbolSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var symbolColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 104), spacing: 8)]
    }

    var body: some View {
        NavigationStack {
            List {
                // List order is also the baseline VoiceOver focus order.
                builtinSection
                customSection
                symbolSection
                operationSection
            }
            // Return advances this identity after UIKit has the final query,
            // rebuilding the lazy result accessibility tree without replacing
            // the active field on every typed character.
            .id(symbolResultGeneration)
            .listStyle(.insetGrouped)
            .scrollDismissesKeyboard(.immediately)
            .themedListSurface()
            .safeAreaInset(edge: .top, spacing: 0) {
                if let errorMessage = model.errorMessage {
                    saveErrorBanner(errorMessage)
                }
            }
            .accessibilityIdentifier("\(accessibilityPrefix).list")
            .iPadReadableContent(maxWidth: IPadReadableContentWidth.form)
            .navigationTitle(purpose.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(model.isSaving)
                        .accessibilityIdentifier("\(accessibilityPrefix).cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await save() }
                    } label: {
                        HStack(spacing: 6) {
                            if model.isSaving {
                                ProgressView().controlSize(.small)
                            }
                            Text(model.isSaving ? "Saving…" : "Save")
                        }
                    }
                    .disabled(!model.canSave)
                    .accessibilityHint(
                        model.validationMessage.map { "Fix custom input: \($0) Save is disabled." } ?? "Saves the selected icon"
                    )
                    .accessibilityIdentifier("\(accessibilityPrefix).save")
                }
            }
            .interactiveDismissDisabled(model.isSaving)
        }
        .presentationDetents(usesExpandedPresentation ? [.large] : [.medium, .large])
        .presentationCompactAdaptation(.fullScreenCover)
        .presentationDragIndicator(.visible)
    }

    private var usesExpandedPresentation: Bool {
        verticalSizeClass == .compact
    }

    @ViewBuilder
    private var builtinSection: some View {
        if !builtinOptions.isEmpty {
            Section("Built-ins") {
                ForEach(builtinOptions) { option in
                    optionButton(
                        id: option.id,
                        label: option.label,
                        detail: option.detail,
                        value: option.value
                    )
                }
            }
        }
    }

    private var customSection: some View {
        Section {
            emojiGenmojiControl

            if let validationMessage = model.validationMessage {
                errorLabel(validationMessage, prefix: "Input error")
                    .accessibilityIdentifier("\(accessibilityPrefix).validationError")
            }
        } footer: {
            Text("Use the Globe key to switch to the Emoji keyboard if needed.")
        }
    }

    private var emojiGenmojiControl: some View {
        Button {
            glyphInputFocusRequest &+= 1
        } label: {
            HStack(spacing: 12) {
                if let choice = model.selectedCustomChoice {
                    draftPreview(model.draft, size: 28)
                        .frame(width: 36, height: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Choose Emoji or Genmoji")
                            .font(.body.weight(.medium))
                        Text(choice.accessibilityDescription)
                            .font(.caption)
                            .foregroundStyle(.themeComment)
                            .lineLimit(1)
                    }
                } else {
                    Label("Choose Emoji or Genmoji", systemImage: "face.smiling")
                        .font(.body.weight(.medium))
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.themeComment)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(.themeFg)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.isSaving)
        .accessibilityLabel("Choose Emoji or Genmoji")
        .accessibilityValue(model.selectedCustomChoice?.accessibilityDescription ?? "No custom choice selected")
        .accessibilityHint("Opens the current keyboard")
        .accessibilityIdentifier("\(accessibilityPrefix).emojiGenmoji")
        .background {
            AdaptiveGlyphInput(
                focusRequest: glyphInputFocusRequest,
                onTextChanged: { text in
                    draftGenmojiImage = nil
                    return model.selectEmoji(text, transform: makeEmoji)
                },
                onGenmoji: { data, contentDescription, previewImage in
                    guard model.selectGenmoji(data: data, contentDescription: contentDescription) else {
                        return false
                    }
                    draftGenmojiImage = previewImage
                    return true
                }
            )
            .frame(width: 1, height: 1)
            .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var symbolSection: some View {
        if purpose.allowedMedia.contains(.symbol), let makeSymbol {
            Section(purpose.symbolSectionTitle) {
                SymbolSearchField(
                    text: $symbolSearch,
                    onTextChanged: { submittedSymbolSearch = $0 },
                    onSubmit: { submittedText in
                        submittedSymbolSearch = submittedText
                        symbolResultGeneration &+= 1
                    }
                )
                .frame(minHeight: 44)
                .accessibilityIdentifier("\(accessibilityPrefix).symbolSearch")

                if filteredSymbols.isEmpty {
                    ContentUnavailableView.search(text: submittedSymbolSearch)
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                } else if hasSubmittedSymbolSearch {
                    // Filtered results stay eager List rows so an exact match
                    // is present in the accessibility hierarchy immediately
                    // after the UIKit field submits its query.
                    ForEach(filteredSymbols) { option in
                        symbolButton(option, makeSymbol: makeSymbol)
                    }
                } else {
                    LazyVGrid(columns: symbolColumns, spacing: 8) {
                        ForEach(filteredSymbols) { option in
                            symbolButton(option, makeSymbol: makeSymbol)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    @ViewBuilder
    private var operationSection: some View {
        if model.isSaving {
            Section {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Saving icon…")
                        .foregroundStyle(.themeComment)
                }
                .frame(minHeight: 44)
                .accessibilityIdentifier("\(accessibilityPrefix).loading")
            }
        }
    }

    private func saveErrorBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            errorLabel(message, prefix: "Save error")
                .accessibilityFocused($errorFocused)
                .accessibilityIdentifier("\(accessibilityPrefix).saveError")
            Spacer(minLength: 8)
            Button {
                Task { await save() }
            } label: {
                Label("Retry Save", systemImage: "arrow.clockwise")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("\(accessibilityPrefix).retry")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.themeRed.opacity(0.12))
        .accessibilityElement(children: .contain)
    }

    private func optionButton(id: String, label: String, detail: String?, value: Value) -> some View {
        let selected = model.draft == .value(value)
        return Button {
            selectValue(value)
        } label: {
            HStack(spacing: 12) {
                preview(value, 28)
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.themeFg)
                    if let detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.themeComment)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? .themeBlue : .themeComment)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.isSaving)
        .accessibilityLabel(label)
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("\(accessibilityPrefix).option.\(id)")
    }

    private func symbolButton(
        _ option: IconSymbolOption,
        makeSymbol: (String) -> Value
    ) -> some View {
        let value = makeSymbol(option.symbolName)
        let selected = model.draft == .value(value)
        return Button {
            guard symbolAvailability(option.symbolName) else { return }
            selectValue(value)
        } label: {
            VStack(spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: option.symbolName)
                        .font(.title3)
                        .frame(width: 36, height: 30)
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.themeBlue)
                            .offset(x: 12, y: -6)
                    }
                }
                Text(option.label)
                    .font(.caption)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(selected ? .themeBlue : .themeFg)
            .frame(maxWidth: .infinity, minHeight: 60)
            .padding(.horizontal, 6)
            .background(.themeBlue.opacity(selected ? 0.14 : 0), in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(.themeBlue.opacity(selected ? 0.7 : 0), lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.isSaving)
        .accessibilityLabel(option.label)
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("\(accessibilityPrefix).symbol.\(option.symbolName)")
    }

    private func draftPreview(_ draft: IconPickerDraft<Value>, size: CGFloat) -> AnyView {
        switch draft {
        case .value(let value):
            return preview(value, size)
        case .genmoji(let data, let contentDescription):
            if let draftGenmojiImage {
                return AnyView(
                    Image(uiImage: draftGenmojiImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: size, height: size)
                        .accessibilityHidden(true)
                )
            }
            return genmojiPreview(data, contentDescription, size)
        }
    }

    private func selectValue(_ value: Value) {
        draftGenmojiImage = nil
        model.selectValue(value)
    }

    private func errorLabel(_ message: String, prefix: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.themeRed)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("\(prefix): \(message)")
    }

    @MainActor
    private func save() async {
        let succeeded = await model.save(
            prepareGenmoji: prepareGenmoji,
            commit: commit
        )
        if succeeded {
            dismiss()
        } else if model.errorMessage != nil {
            await Task.yield()
            errorFocused = true
        }
    }
}

// MARK: - Emoji and Genmoji input

private struct AdaptiveGlyphInput: UIViewRepresentable {
    let focusRequest: Int
    let onTextChanged: (String) -> Bool
    let onGenmoji: (Data, String, UIImage?) -> Bool

    func makeUIView(context: Context) -> UITextView {
        let view = AdaptiveGlyphTextView()
        view.delegate = context.coordinator
        view.isEditable = true
        view.isSelectable = true
        view.supportsAdaptiveImageGlyph = true
        view.backgroundColor = .clear
        view.textColor = .clear
        view.tintColor = .clear
        view.isScrollEnabled = false
        view.textContainer.maximumNumberOfLines = 1
        view.textContainer.lineBreakMode = .byClipping
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        // This responder is intentionally tiny and non-accessible: the visible
        // chooser owns the label and feedback, while UIKit owns glyph input.
        view.isAccessibilityElement = false
        view.accessibilityElementsHidden = true
        return view
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.focusIfRequested(focusRequest, textView: uiView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self, handledFocusRequest: focusRequest)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: AdaptiveGlyphInput
        private var handledFocusRequest: Int

        init(parent: AdaptiveGlyphInput, handledFocusRequest: Int) {
            self.parent = parent
            self.handledFocusRequest = handledFocusRequest
        }

        func focusIfRequested(_ request: Int, textView: UITextView) {
            guard request != handledFocusRequest else { return }
            handledFocusRequest = request
            textView.delegate = nil
            textView.attributedText = NSAttributedString()
            textView.delegate = self
            DispatchQueue.main.async { [weak textView] in
                guard let textView, textView.window != nil else { return }
                textView.becomeFirstResponder()
            }
        }
        func textViewDidChange(_ textView: UITextView) {
            let attributedText = textView.attributedText ?? NSAttributedString()
            let range = NSRange(location: 0, length: attributedText.length)
            var adaptiveGlyph: NSAdaptiveImageGlyph?
            attributedText.enumerateAttribute(.adaptiveImageGlyph, in: range) { value, _, stop in
                guard let value = value as? NSAdaptiveImageGlyph else { return }
                adaptiveGlyph = value
                stop.pointee = true
            }

            if let adaptiveGlyph {
                let previewImage = PickerAdaptiveGlyphRenderer.render(adaptiveGlyph, size: 128)
                if parent.onGenmoji(
                    adaptiveGlyph.imageContent,
                    adaptiveGlyph.contentDescription,
                    previewImage
                ) {
                    textView.resignFirstResponder()
                }
                textView.delegate = nil
                textView.attributedText = NSAttributedString()
                textView.delegate = self
                return
            }

            if parent.onTextChanged(textView.text ?? "") {
                textView.resignFirstResponder()
            }
        }
    }
}

@MainActor
private enum PickerAdaptiveGlyphRenderer {
    /// Renders only the trusted glyph object received directly from UIKit's
    /// text input. Persisted bytes never enter this system-glyph path.
    static func render(_ glyph: NSAdaptiveImageGlyph, size: CGFloat) -> UIImage? {
        let textView = UITextView()
        textView.backgroundColor = .clear
        textView.isEditable = false
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0

        let attributed = NSMutableAttributedString(string: "\u{FFFC}")
        attributed.addAttributes(
            [
                .adaptiveImageGlyph: glyph,
                .font: UIFont.systemFont(ofSize: size * 0.8),
            ],
            range: NSRange(location: 0, length: 1)
        )
        textView.attributedText = attributed
        textView.sizeToFit()
        guard textView.bounds.width > 0, textView.bounds.height > 0 else { return nil }

        return UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { context in
            let scale = min(size / textView.bounds.width, size / textView.bounds.height)
            let scaledWidth = textView.bounds.width * scale
            let scaledHeight = textView.bounds.height * scale
            context.cgContext.translateBy(
                x: (size - scaledWidth) / 2,
                y: (size - scaledHeight) / 2
            )
            context.cgContext.scaleBy(x: scale, y: scale)
            textView.layer.render(in: context.cgContext)
        }
    }
}

private final class AdaptiveGlyphTextView: UITextView {
    override var canBecomeFirstResponder: Bool { true }
}
