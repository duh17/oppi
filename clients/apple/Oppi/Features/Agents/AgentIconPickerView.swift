import SwiftUI
import UIKit

private enum AgentIconPickerError: LocalizedError {
    case serverOffline

    var errorDescription: String? { "Server is offline" }
}

enum AgentIconPickerErrorPresentation: Equatable {
    case validation(String)
    case save(String)
}

enum AgentIconPickerAccessibilityFocusTarget: Equatable, Hashable {
    case validation
    case save
}

struct AgentIconPickerAccessibilityFocusRequest: Equatable {
    let target: AgentIconPickerAccessibilityFocusTarget
    let sequence: Int
}

@MainActor @Observable
final class AgentIconPickerModel {
    private(set) var savedValue: IconChoice
    var draft: String {
        didSet {
            if draft != oldValue {
                errorMessage = nil
            }
        }
    }
    private(set) var isSaving = false
    private(set) var errorMessage: String?
    private(set) var accessibilityFocusRequest: AgentIconPickerAccessibilityFocusRequest?
    private var accessibilityFocusSequence = 0

    init(savedValue: IconChoice) {
        self.savedValue = savedValue
        switch savedValue {
        case .emoji(let value): self.draft = value
        case .symbol(let name): self.draft = name
        case .defaultValue, .genmoji: self.draft = ""
        }
    }

    var previewValue: IconChoice? {
        normalizedDraft
    }

    var previewContent: AgentIconContent {
        AgentIconContent.resolve(previewValue)
    }

    var normalizedDraft: IconChoice? {
        switch AgentIconValue.classify(draft) {
        case .emoji(let value):
            return .emoji(value)
        case .symbolCandidate(let value):
            return .symbol(value)
        case .invalid:
            return nil
        }
    }

    var validationMessage: String? {
        switch AgentIconValue.classify(draft) {
        case .emoji:
            return nil
        case .symbolCandidate(let name):
            return UIImage(systemName: name) == nil
                ? "‘\(name)’ isn’t available on this device."
                : nil
        case .invalid(let error):
            return error.message
        }
    }

    var errorPresentation: AgentIconPickerErrorPresentation? {
        if let errorMessage {
            return .save(errorMessage)
        }
        if previewValue != nil || savedValue != .defaultValue,
           let validationMessage {
            return .validation(validationMessage)
        }
        return nil
    }

    var canSave: Bool {
        guard !isSaving,
              validationMessage == nil,
              let normalizedDraft else {
            return false
        }
        return normalizedDraft != savedValue
    }

    var canAttemptSave: Bool {
        !isSaving && previewValue != savedValue
    }

    var canUseDefault: Bool {
        savedValue != .defaultValue && !isSaving
    }

    func selectSuggestion(_ symbolName: String) {
        draft = symbolName
        errorMessage = nil
    }

    func saveCurrent(
        using operation: (IconChoice) async throws -> StoredAgentDefinition
    ) async -> StoredAgentDefinition? {
        guard !isSaving else { return nil }
        guard validationMessage == nil, let normalizedDraft else {
            requestAccessibilityFocus(.validation)
            return nil
        }
        guard normalizedDraft != savedValue else { return nil }
        return await save(normalizedDraft, using: operation)
    }

    func useDefault(
        using operation: (IconChoice) async throws -> StoredAgentDefinition
    ) async -> StoredAgentDefinition? {
        guard canUseDefault else { return nil }
        return await save(.defaultValue, using: operation)
    }

    private func save(
        _ value: IconChoice,
        using operation: (IconChoice) async throws -> StoredAgentDefinition
    ) async -> StoredAgentDefinition? {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        do {
            let updated = try await operation(value)
            savedValue = value
            switch value {
            case .emoji(let emoji): draft = emoji
            case .symbol(let name): draft = name
            case .defaultValue, .genmoji: draft = ""
            }
            return updated
        } catch {
            errorMessage = "Couldn’t save icon. \(error.localizedDescription)"
            requestAccessibilityFocus(.save)
            return nil
        }
    }

    private func requestAccessibilityFocus(_ target: AgentIconPickerAccessibilityFocusTarget) {
        accessibilityFocusSequence &+= 1
        accessibilityFocusRequest = AgentIconPickerAccessibilityFocusRequest(
            target: target,
            sequence: accessibilityFocusSequence
        )
    }
}

struct AgentIconPickerView: View {
    private struct Suggestion: Identifiable {
        let symbolName: String
        let label: String
        var id: String { symbolName }
    }

    private static let suggestions: [Suggestion] = [
        .init(symbolName: "sparkles", label: "Sparkles"),
        .init(symbolName: "brain.head.profile", label: "Thinking"),
        .init(symbolName: "checkmark.shield", label: "Review"),
        .init(symbolName: "magnifyingglass", label: "Search"),
        .init(symbolName: "hammer", label: "Build"),
        .init(symbolName: "ladybug", label: "Debug"),
        .init(symbolName: "paintbrush", label: "Design"),
        .init(symbolName: "books.vertical", label: "Research"),
    ]

    @Environment(\.apiClient) private var apiClient
    @Environment(\.dismiss) private var dismiss

    let agentId: String
    let onSaved: (StoredAgentDefinition) -> Void
    private let saveOperation: ((IconChoice) async throws -> StoredAgentDefinition)?

    @State private var model: AgentIconPickerModel
    @AccessibilityFocusState private var errorFocus: AgentIconPickerAccessibilityFocusTarget?

    init(
        agent: StoredAgentDefinition,
        saveOperation: ((IconChoice) async throws -> StoredAgentDefinition)? = nil,
        onSaved: @escaping (StoredAgentDefinition) -> Void
    ) {
        agentId = agent.id
        self.saveOperation = saveOperation
        self.onSaved = onSaved
        _model = State(initialValue: AgentIconPickerModel(savedValue: agent.definition.icon))
    }

    private var availableSuggestions: [Suggestion] {
        Self.suggestions.filter { UIImage(systemName: $0.symbolName) != nil }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Current Icon") {
                    HStack(spacing: 12) {
                        AgentIconView(
                            value: model.savedValue,
                            size: 32,
                            frameSize: 44,
                            isDecorative: false
                        )
                        Text(currentIconDescription)
                            .foregroundStyle(.themeFg)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(minHeight: 44)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("agent.iconPicker.current")
                }

                Section("Preview") {
                    HStack(spacing: 12) {
                        AgentIconView(
                            value: model.previewValue,
                            size: 32,
                            frameSize: 44,
                            isDecorative: false
                        )
                        Text(previewIconDescription)
                            .foregroundStyle(.themeFg)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(minHeight: 44)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("agent.iconPicker.preview")
                }

                Section {
                    TextField("Emoji or SF Symbol name", text: $model.draft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(model.isSaving)
                        .accessibilityIdentifier("agent.iconPicker.custom")

                    if case .validation(let message) = model.errorPresentation {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.themeRed)
                            .accessibilityLabel("Icon validation error: \(message)")
                            .accessibilityIdentifier("agent.iconPicker.validationError")
                            .accessibilityFocused($errorFocus, equals: .validation)
                    }
                } footer: {
                    Text("Enter one Unicode emoji or an SF Symbol name.")
                }

                Section("Suggested Symbols") {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 88), spacing: 8)],
                        spacing: 8
                    ) {
                        ForEach(availableSuggestions) { suggestion in
                            suggestionButton(suggestion)
                        }
                    }
                    .padding(.vertical, 4)
                }

                if model.savedValue != .defaultValue {
                    Section {
                        Button {
                            Task { await useDefaultIcon() }
                        } label: {
                            Label("Use Default Icon", systemImage: "arrow.counterclockwise")
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!model.canUseDefault)
                        .accessibilityHint("Removes this Agent’s custom icon.")
                        .accessibilityIdentifier("agent.iconPicker.default")
                    }
                }

                if case .save(let message) = model.errorPresentation {
                    Section {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.themeRed)
                            .accessibilityLabel("Icon save error: \(message)")
                            .accessibilityIdentifier("agent.iconPicker.saveError")
                            .accessibilityFocused($errorFocus, equals: .save)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .themedListSurface()
            .accessibilityIdentifier("agent.iconPicker.list")
            .navigationTitle("Agent Icon")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(model.isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await saveCurrentIcon() }
                    } label: {
                        HStack(spacing: 6) {
                            if model.isSaving {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text(model.isSaving ? "Saving…" : "Save")
                        }
                    }
                    .disabled(!model.canAttemptSave)
                    .accessibilityIdentifier("agent.iconPicker.save")
                }
            }
            .interactiveDismissDisabled(model.isSaving)
            .onChange(of: model.accessibilityFocusRequest) { _, request in
                focusAccessibilityError(request)
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var currentIconDescription: String {
        iconDescription(value: model.savedValue, content: AgentIconContent.resolve(model.savedValue))
    }

    private var previewIconDescription: String {
        iconDescription(value: model.previewValue, content: model.previewContent)
    }

    private func iconDescription(value: IconChoice?, content: AgentIconContent) -> String {
        guard let value, value != .defaultValue else { return "Default Agent icon" }
        switch content {
        case .text(let emoji):
            return "Emoji \(emoji)"
        case .symbol(let name):
            return "SF Symbol \(name)"
        case .genmoji(_, let contentDescription):
            return contentDescription
        case .fallback:
            return "Unavailable icon"
        }
    }

    private func focusAccessibilityError(_ request: AgentIconPickerAccessibilityFocusRequest?) {
        guard let request else { return }
        Task { @MainActor in
            await Task.yield()
            errorFocus = request.target
        }
    }

    private func suggestionButton(_ suggestion: Suggestion) -> some View {
        let selected = model.normalizedDraft == .symbol(suggestion.symbolName)
        return Button {
            model.selectSuggestion(suggestion.symbolName)
        } label: {
            VStack(spacing: 6) {
                Image(systemName: suggestion.symbolName)
                    .font(.title3)
                Text(suggestion.label)
                    .font(.caption)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(selected ? .themeBlue : .themeFg)
            .frame(maxWidth: .infinity, minHeight: 52)
            .padding(.horizontal, 4)
            .background(.themeBlue.opacity(selected ? 0.14 : 0), in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(.themeBlue.opacity(selected ? 0.7 : 0), lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.isSaving)
        .accessibilityLabel(suggestion.label)
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityIdentifier("agent.iconPicker.suggestion.\(suggestion.symbolName)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @MainActor
    private func saveCurrentIcon() async {
        if let updated = await model.saveCurrent(using: { icon in
            if let saveOperation {
                return try await saveOperation(icon)
            }
            guard let apiClient else { throw AgentIconPickerError.serverOffline }
            return try await apiClient.updateAgentIcon(agentId: agentId, icon: icon)
        }) {
            onSaved(updated)
            dismiss()
        }
    }

    @MainActor
    private func useDefaultIcon() async {
        if let updated = await model.useDefault(using: { icon in
            if let saveOperation {
                return try await saveOperation(icon)
            }
            guard let apiClient else { throw AgentIconPickerError.serverOffline }
            return try await apiClient.updateAgentIcon(agentId: agentId, icon: icon)
        }) {
            onSaved(updated)
            dismiss()
        }
    }
}
