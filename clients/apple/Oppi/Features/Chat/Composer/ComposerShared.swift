import Foundation
import PhotosUI
import SwiftUI
import UIKit

/// Shared logic between ChatInputBar and ExpandedComposerView.
///
/// Eliminates duplicated private functions for image handling, input manipulation,
/// voice UI helpers, and keyboard management. Both composers delegate to these
/// static functions instead of maintaining their own copies.
enum ComposerShared {

    // MARK: - Voice UI Helpers

    static func micEngineBadge(for manager: VoiceInputManager) -> MicButtonLabel.EngineBadge {
        switch manager.routeIndicator {
        case .auto: return .auto
        case .onDevice: return .onDevice
        case .remote: return .remote
        }
    }

    static func voiceRouteAccessibilityValue(for manager: VoiceInputManager) -> String {
        manager.routeIndicator.accessibilityLabel
    }

    static func accessibilityLabel(isRecording: Bool, isPreparing: Bool) -> String {
        if isRecording { return "Stop recording" }
        if isPreparing { return "Cancel voice input" }
        return "Start voice input"
    }

    // MARK: - Image Handling

    static func loadSelectedPhotos(
        _ items: [PhotosPickerItem],
        into pendingImages: Binding<[PendingImage]>
    ) {
        for item in items {
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self) else { return }
                guard let uiImage = UIImage(data: data) else { return }
                let pending = PendingImage.from(uiImage)
                await MainActor.run {
                    pendingImages.wrappedValue.append(pending)
                }
            }
        }
    }

    static func addCapturedImage(
        _ image: UIImage,
        to pendingImages: Binding<[PendingImage]>
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let pending = PendingImage.from(image)
            DispatchQueue.main.async {
                pendingImages.wrappedValue.append(pending)
            }
        }
    }

    static func removeImage(
        _ id: String,
        from pendingImages: Binding<[PendingImage]>
    ) {
        pendingImages.wrappedValue.removeAll { $0.id == id }
    }

    static func handlePastedImages(
        _ images: [UIImage],
        into pendingImages: Binding<[PendingImage]>
    ) {
        for image in images {
            DispatchQueue.global(qos: .userInitiated).async {
                let pending = PendingImage.from(image)
                DispatchQueue.main.async {
                    pendingImages.wrappedValue.append(pending)
                }
            }
        }
    }

    // MARK: - Input Manipulation

    static func insertSlashCommand(
        _ command: SlashCommand,
        into text: Binding<String>
    ) {
        text.wrappedValue = ComposerAutocomplete.insertSlashCommand(command, into: text.wrappedValue)
    }

    static func insertFileSuggestion(
        _ suggestion: FileSuggestion,
        text: Binding<String>,
        pendingFiles: Binding<[PendingFileReference]>
    ) {
        if let tokenRange = ComposerAutocomplete.activeAtTokenRange(in: text.wrappedValue) {
            text.wrappedValue.replaceSubrange(tokenRange, with: "")
        }
        let ref = PendingFileReference(path: suggestion.path, isDirectory: suggestion.isDirectory)
        if !pendingFiles.wrappedValue.contains(where: { $0.path == ref.path }) {
            pendingFiles.wrappedValue.append(ref)
        }
        if suggestion.isDirectory {
            text.wrappedValue += "@\(suggestion.path)"
        }
    }

    static func removeFile(
        _ id: String,
        from pendingFiles: Binding<[PendingFileReference]>
    ) {
        pendingFiles.wrappedValue.removeAll { $0.id == id }
    }

    static func notifyFileSuggestionContext(
        for newText: String,
        isBusy: Bool,
        onFileSuggestionQuery: ((String?) -> Void)?
    ) {
        let ctx = ComposerAutocomplete.context(for: newText)
        if case .atFile(let query) = ctx, !isBusy {
            onFileSuggestionQuery?(query)
        } else {
            onFileSuggestionQuery?(nil)
        }
    }

    // MARK: - Keyboard / Voice

    static func handleKeyboardRestore(
        suppressKeyboard: Binding<Bool>,
        textBeforeRecording: Binding<String?>,
        voiceInputManager: VoiceInputManager?
    ) {
        suppressKeyboard.wrappedValue = false
        textBeforeRecording.wrappedValue = nil
        if let manager = voiceInputManager, manager.isRecording || manager.isPreparing {
            Task {
                if manager.isRecording {
                    await manager.stopRecording()
                } else {
                    await manager.cancelRecording()
                }
            }
        }
    }
}

// MARK: - Composer File Pill

/// Reusable file reference pill used by both inline and expanded composers.
struct ComposerFilePill: View {
    let file: PendingFileReference
    let onRemove: () -> Void

    var body: some View {
        let icon = file.isDirectory
            ? FileIcon(symbolName: "folder.fill", color: .themeYellow)
            : FileIcon.forPath(file.path)

        HStack(spacing: 4) {
            Image(systemName: icon.symbolName)
                .font(.appTag)
                .foregroundStyle(icon.color)

            Text(file.displayName)
                .font(.caption2.monospaced())
                .foregroundStyle(.themeFg)
                .lineLimit(1)
                .fixedSize()

            Button {
                onRemove()
            } label: {
                Image(systemName: "xmark")
                    .font(.appBadge)
                    .foregroundStyle(.themeComment)
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 6)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .background(.themeComment.opacity(0.1), in: Capsule())
    }
}

// MARK: - Camera Cover

extension View {
    /// Camera full-screen cover shared by inline and expanded composers.
    func composerCameraCover(
        isPresented: Binding<Bool>,
        pendingImages: Binding<[PendingImage]>
    ) -> some View {
        fullScreenCover(isPresented: isPresented) {
            CameraPicker(
                onCapture: { image in
                    ComposerShared.addCapturedImage(image, to: pendingImages)
                    isPresented.wrappedValue = false
                },
                onCancel: {
                    isPresented.wrappedValue = false
                }
            )
            .ignoresSafeArea()
        }
    }
}
