import PhotosUI
import SwiftUI

/// Context for a new annotation — which line and side the user tapped.
struct AnnotationComposerContext: Identifiable, Equatable {
    let filePath: String
    let side: AnnotationSide
    let line: Int?
    let codeSnippet: String?

    var id: String {
        "\(filePath):\(side.rawValue):\(line ?? -1)"
    }

    var displayLocation: String {
        guard let line else { return filePath }
        let fileName = (filePath as NSString).lastPathComponent
        return "\(fileName):\(line)"
    }
}

/// Bottom sheet for composing a new annotation on a diff line.
///
/// Matches the ChatInputBar quality bar: glass capsule container,
/// multi-line text input, image attachments, severity picker.
struct AnnotationComposerSheet: View {
    let context: AnnotationComposerContext
    let onSubmit: (String, AnnotationSeverity, [PendingImage]) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    @State private var text = ""
    @State private var severity: AnnotationSeverity = .info
    @State private var pendingImages: [PendingImage] = []
    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var showPhotoPicker = false
    @State private var showCamera = false
    @FocusState private var isTextFocused: Bool

    private var canSubmit: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Line context header
                lineContextHeader

                Divider().overlay(theme.text.tertiary.opacity(0.2))

                // Composer area
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        // Image strip
                        if !pendingImages.isEmpty {
                            imageStrip
                        }

                        // Text input
                        TextField("Add a note…", text: $text, axis: .vertical)
                            .font(.body)
                            .lineLimit(3...12)
                            .focused($isTextFocused)
                            .padding(.horizontal, 4)
                    }
                    .padding(16)
                }

                Divider().overlay(theme.text.tertiary.opacity(0.2))

                // Action row: attach + severity pills
                actionRow
            }
            .background(Color.themeBgDark)
            .navigationTitle("Add Annotation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { submit() }
                        .fontWeight(.semibold)
                        .disabled(!canSubmit)
                }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker(
                    onCapture: { image in
                        addImage(image)
                        showCamera = false
                    },
                    onCancel: { showCamera = false }
                )
                .ignoresSafeArea()
            }
            .onAppear { isTextFocused = true }
        }
    }

    // MARK: - Line Context Header

    private var lineContextHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                let icon = FileIcon.forPath(context.filePath)
                Image(systemName: icon.symbolName)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(icon.color)

                Text(context.displayLocation)
                    .font(.subheadline.weight(.semibold).monospaced())
                    .foregroundStyle(theme.text.primary)

                Spacer()

                Text(context.side == .old ? "old" : "new")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(theme.text.tertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(theme.text.tertiary.opacity(0.1), in: Capsule())
            }

            if let snippet = context.codeSnippet, !snippet.isEmpty {
                Text(snippet)
                    .font(.caption.monospaced())
                    .foregroundStyle(theme.text.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.themeBgHighlight)
    }

    // MARK: - Action Row

    private var actionRow: some View {
        HStack(spacing: 8) {
            // Attach button
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
                Image(systemName: "plus")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(theme.text.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .glassEffect(.regular, in: Capsule())
            }
            .photosPicker(
                isPresented: $showPhotoPicker,
                selection: $photoSelection,
                maxSelectionCount: 5,
                matching: .images
            )
            .onChange(of: photoSelection) { _, items in
                loadSelectedPhotos(items)
            }

            // Severity picker pills
            ForEach([AnnotationSeverity.info, .warn, .error], id: \.rawValue) { sev in
                severityPill(sev)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func severityPill(_ sev: AnnotationSeverity) -> some View {
        let isSelected = severity == sev
        let color = severityColor(sev)

        return Button {
            severity = sev
        } label: {
            HStack(spacing: 3) {
                Image(systemName: sev.iconName)
                    .font(.system(size: 9))
                Text(sev.displayLabel)
                    .font(.caption2.weight(.medium))
            }
            .foregroundStyle(isSelected ? .white : color)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                isSelected ? color : color.opacity(0.1),
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
    }

    private func severityColor(_ sev: AnnotationSeverity) -> Color {
        switch sev {
        case .info: return theme.accent.blue
        case .warn: return theme.accent.orange
        case .error: return theme.accent.red
        }
    }

    // MARK: - Image Strip

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
                            pendingImages.removeAll { $0.id == pending.id }
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
        }
    }

    // MARK: - Actions

    private func submit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSubmit(trimmed, severity, pendingImages)
        dismiss()
    }

    private func addImage(_ image: UIImage) {
        DispatchQueue.global(qos: .userInitiated).async {
            let pending = PendingImage.from(image)
            DispatchQueue.main.async {
                pendingImages.append(pending)
            }
        }
    }

    private func loadSelectedPhotos(_ items: [PhotosPickerItem]) {
        for item in items {
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let uiImage = UIImage(data: data) else { return }
                addImage(uiImage)
            }
        }
        photoSelection = []
    }
}
