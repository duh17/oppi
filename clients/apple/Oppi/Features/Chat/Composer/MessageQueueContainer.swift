import SwiftUI
import UIKit

struct MessageQueueSurfaceConfiguration {
    let queue: MessageQueueState
    let onRemove: (String) async throws -> Void
    let onEditInComposer: () async throws -> Void
    var error: String? = nil

    var hasVisibleEntry: Bool { !queue.steering.isEmpty || !queue.followUp.isEmpty }
}

enum MessageQueueContainerPresentation {
    case standalone
    case drawer
}

struct MessageQueueContainer: View {
    private static let queuedAttachmentTileSize: CGFloat = 36
    let configuration: MessageQueueSurfaceConfiguration
    var presentation: MessageQueueContainerPresentation = .standalone
    @State private var isExpanded = false
    @State private var isUpdating = false
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if presentation == .standalone {
                Button {
                    withAnimation(.easeOut(duration: 0.1)) { isExpanded.toggle() }
                } label: {
                    HStack {
                        Text("Message Queue").font(.caption.weight(.semibold))
                        Spacer()
                        Text(MessageQueueAttachmentPresentation.countSubtitle(
                            steeringCount: configuration.queue.steering.count,
                            followUpCount: configuration.queue.followUp.count
                        )).font(.caption2)
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    }
                    .foregroundStyle(.themeFg)
                    .frame(minHeight: 36)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("chat.messageQueue.toggle")
            }
            if let error = configuration.error ?? errorText {
                Text(error).font(.caption).foregroundStyle(.themeRed)
                    .accessibilityIdentifier("chat.messageQueue.error")
            }
            if presentation == .drawer || isExpanded {
                queueSection(title: "Steering", items: configuration.queue.steering)
                queueSection(title: "Follow-up", items: configuration.queue.followUp)
                HStack {
                    Button("Edit in composer") { update { try await configuration.onEditInComposer() } }
                        .accessibilityIdentifier("chat.messageQueue.editInComposer")
                        .disabled(isUpdating || !configuration.hasVisibleEntry)
                    if isUpdating { ProgressView().controlSize(.mini) }
                }
                .font(.caption.weight(.semibold))
            }
        }
        .padding(presentation == .standalone ? 12 : 0)
    }

    @ViewBuilder
    private func queueSection(title: String, items: [MessageQueueItem]) -> some View {
        if !items.isEmpty {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.themeComment)
            ForEach(items) { item in
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.message).font(.caption).foregroundStyle(.themeFg)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        queuedAttachmentStrip(for: item)
                    }
                    .padding(8)
                    .background(.themeRecessedInset, in: RoundedRectangle(cornerRadius: 10))
                    Button {
                        update { try await configuration.onRemove(item.id) }
                    } label: {
                        Image(systemName: "trash")
                            .frame(width: 45, height: 45)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.themeComment)
                    .disabled(isUpdating)
                    .accessibilityLabel("Remove queued message")
                    .accessibilityIdentifier("chat.messageQueue.remove.\(item.id)")
                }
            }
        }
    }

    private func update(_ operation: @escaping () async throws -> Void) {
        guard !isUpdating else { return }
        isUpdating = true
        errorText = nil
        Task { @MainActor in
            defer { isUpdating = false }
            do { try await operation() }
            catch { errorText = error.localizedDescription }
        }
    }

    @ViewBuilder
    private func queuedAttachmentStrip(for item: MessageQueueItem) -> some View {
        let chips = MessageQueueAttachmentPresentation.visibleAttachments(for: item)
        if !chips.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(chips) { chip in
                        queuedAttachmentChip(chip)
                    }
                }
            }
            .frame(height: Self.queuedAttachmentTileSize)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func queuedAttachmentChip(_ chip: MessageQueueVisibleAttachment) -> some View {
        switch chip {
        case .photo(let id, let name, let image):
            queuedPhotoThumb(id: id, name: name, image: image)
        case .file(let id, let name):
            QueuedAttachmentPill(id: id, name: name)
        }
    }

    @ViewBuilder
    private func queuedPhotoThumb(id: String, name: String, image: ImageAttachment?) -> some View {
        let decodedImage: UIImage? = {
            guard let image,
                  let data = Data(base64Encoded: image.data, options: .ignoreUnknownCharacters) else {
                return nil
            }
            return UIImage(data: data)
        }()

        Group {
            if let decodedImage {
                Image(uiImage: decodedImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Rectangle().fill(.themeRecessedInset)
                    Image(systemName: "photo")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.themeComment)
                }
            }
        }
        .frame(width: Self.queuedAttachmentTileSize, height: Self.queuedAttachmentTileSize)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.themeComment.opacity(0.3), lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("chat.messageQueue.attachment.\(id)")
        .accessibilityLabel("Photo \(name)")
    }

}

private struct QueuedAttachmentPill: View {
    let id: String
    let name: String

    var body: some View {
        HStack(spacing: 4) {
            FileIcon.forPath(name).iconView(size: 12, font: .appTag)

            Text(name)
                .font(.caption2.monospaced())
                .foregroundStyle(.themeFg)
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.themeComment.opacity(0.1), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("chat.messageQueue.attachment.\(id)")
        .accessibilityLabel("Attachment \(name)")
    }
}
