import SwiftUI
import UIKit
import os.log

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "SkillEditor")

// MARK: - SkillEditorView

/// Native markdown editor for SKILL.md files and other text content.
///
/// Features:
/// - Live syntax highlighting (headings, bold, italic, code, frontmatter, links)
/// - Formatting toolbar (heading, bold, italic, code, link, list, checkbox)
/// - Split preview mode (edit + rendered markdown side by side on iPad, toggle on iPhone)
/// - Keyboard shortcuts (⌘B bold, ⌘I italic, ⌘K link)
/// - Auto-save indicator + explicit save
///
/// Used for editing skills inline from the iOS app. Calls
/// `PUT /me/skills/:name` to persist changes to the server.
struct SkillEditorView: View {
    let skillName: String
    let filePath: String
    let initialContent: String
    /// True when creating a brand new skill (vs editing existing).
    var isNew: Bool = false

    @Environment(ServerConnection.self) private var connection
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var content: String
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var showPreview = false
    @State private var hasUnsavedChanges = false
    @State private var showDiscardAlert = false

    init(skillName: String, filePath: String = "SKILL.md", initialContent: String = "", isNew: Bool = false) {
        self.skillName = skillName
        self.filePath = filePath
        self.initialContent = initialContent
        self.isNew = isNew
        _content = State(initialValue: initialContent)
    }

    private var isMarkdown: Bool {
        filePath.hasSuffix(".md")
    }

    private var title: String {
        isNew ? "New Skill" : filePath.components(separatedBy: "/").last ?? filePath
    }

    var body: some View {
        editorBody
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(hasUnsavedChanges)
            .toolbar { toolbarItems }
            .alert("Unsaved Changes", isPresented: $showDiscardAlert) {
                Button("Discard", role: .destructive) { dismiss() }
                Button("Keep Editing", role: .cancel) { }
            } message: {
                Text("You have unsaved changes. Discard them?")
            }
            .alert("Save Failed", isPresented: .init(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil } }
            )) {
                Button("OK") { saveError = nil }
            } message: {
                if let err = saveError { Text(err) }
            }
    }

    // MARK: - Body

    @ViewBuilder
    private var editorBody: some View {
        if showPreview && isMarkdown {
            if sizeClass == .regular {
                // iPad: side by side
                HStack(spacing: 0) {
                    editorPane
                    Divider()
                    previewPane
                }
            } else {
                // iPhone: full preview
                previewPane
            }
        } else {
            editorPane
        }
    }

    private var editorPane: some View {
        HighlightingTextEditor(
            text: $content,
            isMarkdown: isMarkdown,
            font: .monospacedSystemFont(ofSize: 14, weight: .regular),
            textColor: UIColor(theme.text.primary),
            backgroundColor: UIColor(theme.bg.primary),
            tintColor: UIColor(theme.accent.blue),
            onInsert: nil
        )
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .onChange(of: content) { _, _ in
            hasUnsavedChanges = (content != initialContent)
        }
    }

    private var previewPane: some View {
        ScrollView {
            MarkdownText(content)
                .padding()
        }
        .background(theme.bg.primary)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            if hasUnsavedChanges {
                Button("Cancel") {
                    showDiscardAlert = true
                }
            }
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                Task { await save() }
            } label: {
                if isSaving {
                    ProgressView()
                } else {
                    Text("Save")
                        .fontWeight(.semibold)
                }
            }
            .disabled(isSaving || !hasUnsavedChanges)
        }

        if isMarkdown {
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showPreview.toggle()
                    }
                } label: {
                    Label(
                        showPreview ? "Editor" : "Preview",
                        systemImage: showPreview ? "pencil" : "eye"
                    )
                }
            }
        }

        ToolbarItemGroup(placement: .keyboard) {
            formattingToolbar
        }
    }

    // MARK: - Formatting Toolbar

    @ViewBuilder
    private var formattingToolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                FormatButton(icon: "number", label: "Heading") {
                    insertAtLineStart("# ")
                }
                FormatButton(icon: "bold", label: "Bold") {
                    wrapSelection(with: "**")
                }
                FormatButton(icon: "italic", label: "Italic") {
                    wrapSelection(with: "*")
                }
                FormatButton(icon: "chevron.left.forwardslash.chevron.right", label: "Code") {
                    wrapSelection(with: "`")
                }
                FormatButton(icon: "link", label: "Link") {
                    insertLink()
                }
                FormatButton(icon: "list.bullet", label: "List") {
                    insertAtLineStart("- ")
                }
                FormatButton(icon: "checklist", label: "Checkbox") {
                    insertAtLineStart("- [ ] ")
                }
                FormatButton(icon: "text.quote", label: "Quote") {
                    insertAtLineStart("> ")
                }
                FormatButton(icon: "rectangle.split.1x2", label: "Fence") {
                    insertCodeFence()
                }

                Spacer()

                Button {
                    UIApplication.shared.sendAction(
                        #selector(UIResponder.resignFirstResponder),
                        to: nil, from: nil, for: nil
                    )
                } label: {
                    Image(systemName: "keyboard.chevron.compact.down")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 4)
        }
    }

    // MARK: - Format Actions

    /// Post a notification that the HighlightingTextEditor will pick up.
    private func wrapSelection(with wrapper: String) {
        NotificationCenter.default.post(
            name: .editorFormatAction,
            object: nil,
            userInfo: ["action": FormatAction.wrapSelection(wrapper)]
        )
    }

    private func insertAtLineStart(_ prefix: String) {
        NotificationCenter.default.post(
            name: .editorFormatAction,
            object: nil,
            userInfo: ["action": FormatAction.insertAtLineStart(prefix)]
        )
    }

    private func insertLink() {
        NotificationCenter.default.post(
            name: .editorFormatAction,
            object: nil,
            userInfo: ["action": FormatAction.insertSnippet("[", "](url)")]
        )
    }

    private func insertCodeFence() {
        NotificationCenter.default.post(
            name: .editorFormatAction,
            object: nil,
            userInfo: ["action": FormatAction.insertSnippet("```\n", "\n```")]
        )
    }

    // MARK: - Save

    private func save() async {
        guard let api = connection.apiClient else {
            saveError = "Not connected to server"
            return
        }

        isSaving = true
        defer { isSaving = false }

        do {
            if filePath == "SKILL.md" {
                // Save the whole skill via PUT
                try await api.putUserSkill(name: skillName, content: content)
            } else {
                // Save individual file
                try await api.putUserSkill(
                    name: skillName,
                    content: nil, // don't overwrite SKILL.md
                    files: [filePath: content]
                )
            }
            hasUnsavedChanges = false
            logger.info("Saved \(filePath) for skill \(skillName)")

            if isNew {
                dismiss()
            }
        } catch {
            logger.error("Save failed: \(error.localizedDescription)")
            saveError = error.localizedDescription
        }
    }
}

// MARK: - FormatAction

enum FormatAction {
    case wrapSelection(String)
    case insertAtLineStart(String)
    case insertSnippet(String, String)
}

extension Notification.Name {
    static let editorFormatAction = Notification.Name("\(AppIdentifiers.subsystem).editorFormatAction")
}

// MARK: - FormatButton

private struct FormatButton: View {
    let icon: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
    }
}

// MARK: - HighlightingTextEditor (UIViewRepresentable)

/// UITextView wrapper with live markdown syntax highlighting.
///
/// Uses ``MarkdownTextStorage`` for highlighting and responds to
/// ``FormatAction`` notifications from the toolbar.
struct HighlightingTextEditor: UIViewRepresentable {
    @Binding var text: String
    let isMarkdown: Bool
    let font: UIFont
    let textColor: UIColor
    let backgroundColor: UIColor
    let tintColor: UIColor
    let onInsert: ((String) -> Void)?

    func makeUIView(context: Context) -> UITextView {
        let storage = MarkdownTextStorage()
        storage.bodyFont = font

        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)

        let textView = UITextView(frame: .zero, textContainer: container)
        textView.delegate = context.coordinator
        textView.font = font
        textView.textColor = textColor
        textView.backgroundColor = backgroundColor
        textView.tintColor = tintColor
        textView.autocorrectionType = UITextAutocorrectionType.no
        textView.autocapitalizationType = UITextAutocapitalizationType.none
        textView.smartQuotesType = UITextSmartQuotesType.no
        textView.smartDashesType = UITextSmartDashesType.no
        textView.smartInsertDeleteType = UITextSmartInsertDeleteType.no
        textView.keyboardDismissMode = UIScrollView.KeyboardDismissMode.interactive
        textView.alwaysBounceVertical = true
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
        textView.isScrollEnabled = true

        // Set initial content — this triggers highlighting
        if !text.isEmpty {
            storage.replaceCharacters(
                in: NSRange(location: 0, length: 0),
                with: text
            )
        }

        context.coordinator.textView = textView
        context.coordinator.storage = storage

        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        // Only update if text changed externally (not from typing)
        if let storage = context.coordinator.storage,
           storage.string != text {
            let selectedRange = textView.selectedRange
            storage.replaceCharacters(
                in: NSRange(location: 0, length: storage.length),
                with: text
            )
            // Restore cursor if possible
            let safeRange = NSRange(
                location: min(selectedRange.location, storage.length),
                length: 0
            )
            textView.selectedRange = safeRange
        }

        textView.backgroundColor = backgroundColor
        textView.tintColor = tintColor
    }

    static func dismantleUIView(_ uiView: UITextView, coordinator: Coordinator) {
        coordinator.cleanup()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        @Binding var text: String
        weak var textView: UITextView?
        weak var storage: MarkdownTextStorage?
        private var formatObserver: (any NSObjectProtocol)?

        init(text: Binding<String>) {
            _text = text
            super.init()

            // Listen for format actions from toolbar
            formatObserver = NotificationCenter.default.addObserver(
                forName: .editorFormatAction,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self,
                      let action = notification.userInfo?["action"] as? FormatAction,
                      let tv = self.textView else { return }
                self.apply(action, to: tv)
            }
        }

        func cleanup() {
            if let observer = formatObserver {
                NotificationCenter.default.removeObserver(observer)
                formatObserver = nil
            }
        }

        func textViewDidChange(_ textView: UITextView) {
            text = textView.text
        }

        // MARK: - Format Actions

        private func apply(_ action: FormatAction, to tv: UITextView) {
            let selected = tv.selectedRange

            switch action {
            case .wrapSelection(let wrapper):
                if selected.length > 0 {
                    // Wrap existing selection
                    let nsText = tv.text as NSString
                    let selectedText = nsText.substring(with: selected)
                    let replacement = wrapper + selectedText + wrapper
                    tv.textStorage.replaceCharacters(in: selected, with: replacement)
                    // Select the inner text
                    tv.selectedRange = NSRange(
                        location: selected.location + wrapper.count,
                        length: selected.length
                    )
                } else {
                    // Insert wrapper pair and place cursor inside
                    let pair = wrapper + wrapper
                    tv.textStorage.replaceCharacters(in: selected, with: pair)
                    tv.selectedRange = NSRange(location: selected.location + wrapper.count, length: 0)
                }
                text = tv.text

            case .insertAtLineStart(let prefix):
                let nsText = tv.text as NSString
                let lineRange = nsText.lineRange(for: NSRange(location: selected.location, length: 0))
                tv.textStorage.replaceCharacters(
                    in: NSRange(location: lineRange.location, length: 0),
                    with: prefix
                )
                tv.selectedRange = NSRange(location: selected.location + prefix.count, length: selected.length)
                text = tv.text

            case .insertSnippet(let before, let after):
                if selected.length > 0 {
                    let nsText = tv.text as NSString
                    let selectedText = nsText.substring(with: selected)
                    let replacement = before + selectedText + after
                    tv.textStorage.replaceCharacters(in: selected, with: replacement)
                    tv.selectedRange = NSRange(
                        location: selected.location + before.count,
                        length: selected.length
                    )
                } else {
                    let snippet = before + after
                    tv.textStorage.replaceCharacters(in: selected, with: snippet)
                    tv.selectedRange = NSRange(location: selected.location + before.count, length: 0)
                }
                text = tv.text
            }
        }


    }
}

// MARK: - Navigation Destination

struct SkillEditorDestination: Hashable {
    let skillName: String
    let filePath: String
    let content: String
    let isNew: Bool
}
