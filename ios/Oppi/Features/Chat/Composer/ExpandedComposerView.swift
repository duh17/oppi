import PhotosUI
import SwiftUI
import UIKit

/// Full-screen composer for long-form text input.
///
/// Opens as a sheet from `ChatInputBar` when the user taps the expand button.
/// Shares text/image bindings with the inline input so edits carry over in both
/// directions. Supports bash mode ($ prefix), image attachments, and paste.
///
/// Layout:
/// ```
/// ┌─────────────────────────────┐
/// │ Cancel    Compose     Send  │  toolbar
/// ├─────────────────────────────┤
/// │ [bash mode banner]          │  conditional
/// ├─────────────────────────────┤
/// │                             │
/// │  Full-height text editor    │
/// │  (scrollable)               │
/// │                             │
/// ├─────────────────────────────┤
/// │ [image strip]               │  conditional
/// │ [+]             42w · 256c  │  attach + stats
/// └─────────────────────────────┘
/// ```
struct ExpandedComposerView: View {
    @Binding var text: String
    @Binding var pendingImages: [PendingImage]
    let isBusy: Bool
    let slashCommands: [SlashCommand]
    let session: Session?
    let thinkingLevel: ThinkingLevel
    let onSend: () -> Void
    let onModelTap: () -> Void
    let onThinkingSelect: (ThinkingLevel) -> Void
    let onCompact: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var showPhotoPicker = false
    @State private var showCamera = false

    private var canSend: Bool {
        let hasImages = !pendingImages.isEmpty
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasText || hasImages
    }

    private var accentColor: Color { .themeBlue }
    private var composerInputFont: UIFont { .preferredFont(forTextStyle: .body) }
    private var composerAutocorrectionEnabled: Bool { true }

    private var autocompleteContext: ComposerAutocompleteContext {
        guard !isBusy else { return .none }
        return ComposerAutocomplete.context(for: text)
    }

    private var slashSuggestions: [SlashCommand] {
        guard case .slash(let query) = autocompleteContext else {
            return []
        }
        return ComposerAutocomplete.slashSuggestions(query: query, commands: slashCommands)
    }

    /// Text binding that strips the "$ " prefix for bash mode display.
    private var textFieldBinding: Binding<String> {
        Binding(
            get: {
                if text.hasPrefix("$ ") {
                    return String(text.dropFirst(2))
                }
                return text
            },
            set: { newValue in
                if text.hasPrefix("$ ") {
                    text = newValue.isEmpty ? "" : "$ " + newValue
                } else {
                    text = newValue
                }
            }
        )
    }

    private var wordCount: Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    private var charCount: Int { text.count }

    private var lineCount: Int {
        max(1, text.components(separatedBy: "\n").count)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {

                FullSizeTextView(
                    text: textFieldBinding,
                    font: composerInputFont,
                    textColor: UIColor(Color.themeFg),
                    tintColor: UIColor(accentColor),
                    autocorrectionEnabled: composerAutocorrectionEnabled,
                    onPasteImages: handlePastedImages,
                    onCommandEnter: handleSend,
                    autoFocusOnAppear: false
                )

                if !slashSuggestions.isEmpty {
                    SlashCommandSuggestionList(suggestions: slashSuggestions, onSelect: insertSlashCommand)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                }

                Divider().overlay(Color.themeComment.opacity(0.2))

                bottomBar
            }
            .background(Color.themeBg)
            .navigationTitle(isBusy ? "Steer Agent" : "Compose")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(Color.themeBgDark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                    .foregroundStyle(.themeFgDim)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        handleSend()
                    } label: {
                        Text("Send")
                            .fontWeight(.semibold)
                    }
                    .disabled(!canSend)
                    .foregroundStyle(canSend ? accentColor : .themeComment)
                }
            }
        }
        .preferredColorScheme(ThemeRuntimeState.currentThemeID().preferredColorScheme)
        .onChange(of: photoSelection) { _, items in
            loadSelectedPhotos(items)
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker(
                onCapture: { image in
                    addCapturedImage(image)
                    showCamera = false
                },
                onCancel: {
                    showCamera = false
                }
            )
            .ignoresSafeArea()
        }
    }

    // MARK: - Subviews

    private var bottomBar: some View {
        VStack(spacing: 8) {
            if !pendingImages.isEmpty {
                imageStrip
            }

            HStack(spacing: 6) {
                attachMenu

                Spacer(minLength: 0)

                SessionToolbar(
                    session: session,
                    thinkingLevel: thinkingLevel,
                    onModelTap: onModelTap,
                    onThinkingSelect: onThinkingSelect,
                    onCompact: onCompact
                )
            }
            .padding(.horizontal, 16)

            HStack {
                Spacer()

                if charCount > 0 {
                    HStack(spacing: 8) {
                        Text("\(lineCount)L")
                        Text("\(wordCount)W")
                        Text("\(charCount)C")
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.themeComment)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .padding(.top, 8)
        .background(Color.themeBgDark)
    }

    private var imageStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(pendingImages) { pending in
                    ZStack(alignment: .topTrailing) {
                        Image(uiImage: pending.thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 56, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.themeComment.opacity(0.3), lineWidth: 1)
                            )

                        Button {
                            removeImage(pending.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.white)
                                .background(Circle().fill(.black.opacity(0.6)))
                        }
                        .offset(x: 4, y: -4)
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private var attachMenu: some View {
        Menu {
            Button {
                showPhotoPicker = true
            } label: {
                Label("Photo Library", systemImage: "photo.on.rectangle")
            }

            Button {
                showCamera = true
            } label: {
                Label("Camera", systemImage: "camera")
            }
        } label: {
            Image(systemName: "plus.circle.fill")
                .font(.title3)
                .foregroundStyle(.themeBlue)
                .symbolRenderingMode(.hierarchical)
        }
        .photosPicker(
            isPresented: $showPhotoPicker,
            selection: $photoSelection,
            maxSelectionCount: 5,
            matching: .images
        )
    }

    // MARK: - Actions

    private func handleSend() {
        onSend()
        dismiss()
    }

    private func insertSlashCommand(_ command: SlashCommand) {
        text = ComposerAutocomplete.insertSlashCommand(command, into: text)
    }

    private func handlePastedImages(_ images: [UIImage]) {
        for image in images {
            let pending = PendingImage.from(image)
            pendingImages.append(pending)
        }
    }

    private func loadSelectedPhotos(_ items: [PhotosPickerItem]) {
        for item in items {
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self) else { return }
                guard let uiImage = UIImage(data: data) else { return }
                let pending = PendingImage.from(uiImage)
                await MainActor.run {
                    pendingImages.append(pending)
                }
            }
        }
        photoSelection = []
    }

    private func addCapturedImage(_ image: UIImage) {
        let pending = PendingImage.from(image)
        pendingImages.append(pending)
    }

    private func removeImage(_ id: String) {
        pendingImages.removeAll { $0.id == id }
    }
}
