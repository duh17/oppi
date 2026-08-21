import SwiftUI
import UIKit

private extension View {
    func messageQueuePanelChrome(cornerRadius: CGFloat = 18) -> some View {
        self
            .themedSurface(
                .elevatedPanel,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .shadow(color: Color.black.opacity(0.18), radius: 10, x: 0, y: 2)
    }
}

struct MessageQueueSurfaceConfiguration {
    let queue: MessageQueueState
    let busyStreamingBehavior: Binding<StreamingBehavior>
    let editorState: Binding<MessageQueueEditorState>
    let onApply: (_ baseVersion: Int, _ steering: [MessageQueueDraftItem], _ followUp: [MessageQueueDraftItem]) async throws -> Void
    let onRefresh: () async -> Void

    var hasVisibleEntry: Bool {
        !queue.steering.isEmpty
            || !queue.followUp.isEmpty
            || editorState.wrappedValue.isDraftMode
            || editorState.wrappedValue.hasStashedDraft
    }
}

enum MessageQueueContainerPresentation {
    case standalone
    case drawer
}

struct MessageQueueContainer: View {
    private static let queuedAttachmentTileSize: CGFloat = 36

    private struct StatusBannerModel {
        let title: String
        let message: String
        let color: Color
    }

    let queue: MessageQueueState
    @Binding var busyStreamingBehavior: StreamingBehavior
    let onApply: (_ baseVersion: Int, _ steering: [MessageQueueDraftItem], _ followUp: [MessageQueueDraftItem]) async throws -> Void
    let onRefresh: () async -> Void
    let presentation: MessageQueueContainerPresentation

    @State private var isExpanded = false
    @Binding private var editorState: MessageQueueEditorState
    @State private var isApplying = false
    @State private var isRefreshing = false
    @State private var errorText: String?

    init(
        queue: MessageQueueState,
        busyStreamingBehavior: Binding<StreamingBehavior>,
        editorState: Binding<MessageQueueEditorState>,
        onApply: @escaping (_ baseVersion: Int, _ steering: [MessageQueueDraftItem], _ followUp: [MessageQueueDraftItem]) async throws -> Void,
        onRefresh: @escaping () async -> Void,
        presentation: MessageQueueContainerPresentation = .standalone
    ) {
        self.queue = queue
        _busyStreamingBehavior = busyStreamingBehavior
        _editorState = editorState
        self.onApply = onApply
        self.onRefresh = onRefresh
        self.presentation = presentation
    }

    init(
        configuration: MessageQueueSurfaceConfiguration,
        presentation: MessageQueueContainerPresentation = .standalone
    ) {
        self.init(
            queue: configuration.queue,
            busyStreamingBehavior: configuration.busyStreamingBehavior,
            editorState: configuration.editorState,
            onApply: configuration.onApply,
            onRefresh: configuration.onRefresh,
            presentation: presentation
        )
    }

    private var displayedQueue: MessageQueueState {
        editorState.displayedQueue
    }

    private var controlsDisabled: Bool {
        isApplying || isRefreshing
    }

    private var statusBannerModel: StatusBannerModel? {
        if let conflict = editorState.conflict {
            return StatusBannerModel(
                title: conflict.title,
                message: conflict.message,
                color: .themeOrange
            )
        }
        if editorState.isDraftMode {
            return StatusBannerModel(
                title: "Unsaved text edits",
                message: "Save to replace the current queue with your updated draft.",
                color: .themeComment
            )
        }
        if editorState.hasStashedDraft {
            return StatusBannerModel(
                title: "Reviewing latest queue",
                message: "Your earlier draft is still available if you want to restore it.",
                color: .themeComment
            )
        }
        return nil
    }

    private var isQueueEmpty: Bool {
        displayedQueue.steering.isEmpty && displayedQueue.followUp.isEmpty
    }

    private var showsExpandedContent: Bool {
        presentation == .drawer || isExpanded
    }

    var body: some View {
        Group {
            if presentation == .standalone {
                content
                    .padding(.horizontal, 12)
                    .padding(.vertical, isExpanded ? 10 : 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .messageQueuePanelChrome(cornerRadius: 18)
            } else {
                content
            }
        }
        .accessibilityElement(children: .contain)
        .onAppear {
            editorState.receiveServerQueue(queue, isExpanded: showsExpandedContent)
        }
        .onChange(of: queue) { _, latestQueue in
            editorState.receiveServerQueue(latestQueue, isExpanded: showsExpandedContent)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            if presentation == .standalone {
                header
            }

            if showsExpandedContent {
                expandedContent
            }
        }
    }

    @ViewBuilder
    private var expandedContent: some View {
        busyModePicker

        if let banner = statusBannerModel {
            statusBanner(title: banner.title, message: banner.message, color: banner.color)
        }

        if let errorText, !errorText.isEmpty {
            statusBanner(title: "Queue update failed", message: errorText, color: .themeRed)
        }

        if isQueueEmpty {
            Text("Queue is empty")
                .font(.caption)
                .foregroundStyle(.themeComment)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
        } else {
            queueSection(
                title: "Steering Queue",
                kind: .steer,
                items: displayedQueue.steering
            )
            queueSection(
                title: "Follow-up Queue",
                kind: .followUp,
                items: displayedQueue.followUp
            )
        }

        footerActions
    }

    private var header: some View {
        Button {
            withAnimation(.easeOut(duration: 0.10)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 8) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(messageQueueStatusColor)
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)

                    Text("Message Queue")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.themeFg)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 6) {
                    countPill(count: displayedQueue.steering.count, label: "steering", tint: .themeBlue)
                    countPill(count: displayedQueue.followUp.count, label: "follow-up", tint: .themePurple)
                }
                .fixedSize(horizontal: true, vertical: false)

                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.themeComment)
                    .frame(width: 28, height: 28)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("chat.messageQueue.toggle")
        .accessibilityLabel(isExpanded ? "Collapse message queue" : "Expand message queue")
        .accessibilityValue("\(displayedQueue.steering.count) steering, \(displayedQueue.followUp.count) follow-up")
    }

    private var messageQueueStatusColor: Color {
        isQueueEmpty ? .themeComment : .themeGreen
    }

    private func countPill(count: Int, label: String, tint: Color) -> some View {
        Text("\(count) \(label)")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(count > 0 ? Color.themeFg : Color.themeComment)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.themeFg.opacity(count > 0 ? 0.075 : 0.04), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(count > 0 ? tint.opacity(0.35) : Color.themeFg.opacity(0.08), lineWidth: 1)
            }
    }

    private var busyModePicker: some View {
        Picker("Send while busy", selection: $busyStreamingBehavior) {
            Text("Steering").tag(StreamingBehavior.steer)
            Text("Follow-up").tag(StreamingBehavior.followUp)
        }
        .pickerStyle(.segmented)
    }

    @ViewBuilder
    private func statusBanner(title: String, message: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
            Text(message)
                .font(.caption2)
                .foregroundStyle(.themeComment)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.themeRecessedInset)
        )
    }

    @ViewBuilder
    private func queueSection(
        title: String,
        kind: MessageQueueKind,
        items: [MessageQueueItem]
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.themeComment)
                Spacer()
                Text("\(items.count)")
                    .font(.caption2)
                    .foregroundStyle(.themeComment)
            }

            ForEach(items.indices, id: \.self) { index in
                queueRow(kind: kind, index: index)
            }
        }
    }

    @ViewBuilder
    private func queueRow(kind: MessageQueueKind, index: Int) -> some View {
        let item = queueItems(for: kind)[index]
        let binding = messageBinding(kind: kind, index: index)

        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                TextField(
                    MessageQueueAttachmentPresentation.visibleAttachments(for: item).isEmpty
                        ? "Queued message"
                        : "Add a message (optional)",
                    text: binding,
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .font(.caption)
                .lineLimit(1...3)
                .disabled(isApplying || isRefreshing)

                queuedAttachmentStrip(for: item)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.themeRecessedInset)
            )

            rowActions(kind: kind, index: index)
                .padding(.top, 3)
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
                    Color.themeRecessedInset
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
                .stroke(Color.themeComment.opacity(0.3), lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("chat.messageQueue.attachment.\(id)")
        .accessibilityLabel("Photo \(name)")
    }

    private func rowActions(kind: MessageQueueKind, index: Int) -> some View {
        HStack(spacing: 4) {
            IconActionButton(systemName: "arrow.up") {
                handleRowMutation(editorState.moveItem(kind: kind, from: index, direction: -1))
            }
            .disabled(controlsDisabled || !canMove(kind: kind, index: index, direction: -1))

            IconActionButton(systemName: "arrow.down") {
                handleRowMutation(editorState.moveItem(kind: kind, from: index, direction: 1))
            }
            .disabled(controlsDisabled || !canMove(kind: kind, index: index, direction: 1))

            IconActionButton(systemName: moveBetweenQueuesSystemImage(for: kind)) {
                handleRowMutation(editorState.moveBetweenQueues(kind: kind, index: index))
            }
            .disabled(controlsDisabled)

            IconActionButton(systemName: "trash") {
                handleRowMutation(editorState.deleteItem(kind: kind, index: index))
            }
            .disabled(controlsDisabled)
        }
    }

    private var footerActions: some View {
        HStack(spacing: 8) {
            if controlsDisabled {
                ProgressView()
                    .controlSize(.mini)
            }

            Button("Refresh") {
                refreshQueue()
            }
            .font(.caption)
            .disabled(controlsDisabled)
            .accessibilityIdentifier("chat.messageQueue.refresh")

            Spacer()

            if editorState.hasStashedDraft {
                Button("Restore draft") {
                    editorState.restoreDraft()
                    errorText = nil
                }
                .font(.caption)
                .disabled(controlsDisabled)
            }

            if editorState.isDraftMode {
                draftActions
            }
        }
    }

    @ViewBuilder
    private var draftActions: some View {
        if let conflict = editorState.conflict {
            Button(conflict.reviewActionTitle) {
                editorState.reviewLatest()
                errorText = nil
            }
            .font(.caption)
            .disabled(controlsDisabled)

            saveButton(title: conflict.applyActionTitle)
        } else {
            Button("Discard") {
                editorState.discardDraft()
                errorText = nil
            }
            .font(.caption)
            .disabled(controlsDisabled)

            saveButton(title: "Save")
        }
    }

    private func saveButton(title: String) -> some View {
        Button {
            saveDraft()
        } label: {
            labelText(title)
        }
        .buttonStyle(.borderedProminent)
        .tint(.themeBlue)
        .disabled(controlsDisabled)
    }

    @ViewBuilder
    private func labelText(_ text: String) -> some View {
        if isApplying {
            ProgressView()
                .controlSize(.mini)
                .padding(.horizontal, 4)
        } else {
            Text(text)
                .font(.caption.weight(.semibold))
        }
    }

    private func messageBinding(kind: MessageQueueKind, index: Int) -> Binding<String> {
        Binding(
            get: {
                queueItems(for: kind)[index].message
            },
            set: { newValue in
                if editorState.updateMessage(kind: kind, index: index, message: newValue) {
                    errorText = nil
                }
            }
        )
    }

    private func queueItems(for kind: MessageQueueKind) -> [MessageQueueItem] {
        switch kind {
        case .steer:
            return displayedQueue.steering
        case .followUp:
            return displayedQueue.followUp
        }
    }

    private func canMove(kind: MessageQueueKind, index: Int, direction: Int) -> Bool {
        let items = queueItems(for: kind)
        let target = index + direction
        return items.indices.contains(index) && items.indices.contains(target)
    }

    private func moveBetweenQueuesSystemImage(for kind: MessageQueueKind) -> String {
        switch kind {
        case .steer:
            return "arrow.down.right"
        case .followUp:
            return "arrow.up.left"
        }
    }

    private func handleRowMutation(_ request: MessageQueueMutationRequest?) {
        guard let request else {
            errorText = nil
            return
        }

        applyMutation(request, revertOnFailure: true)
    }

    private func refreshQueue() {
        guard !controlsDisabled else { return }
        isRefreshing = true
        errorText = nil

        Task { @MainActor in
            defer { isRefreshing = false }
            await onRefresh()
        }
    }

    private func saveDraft() {
        guard !controlsDisabled, let request = editorState.draftRequest() else { return }
        applyMutation(request, revertOnFailure: false)
    }

    private func applyMutation(_ request: MessageQueueMutationRequest, revertOnFailure: Bool) {
        guard !controlsDisabled else { return }
        isApplying = true
        errorText = nil

        Task { @MainActor in
            defer { isApplying = false }
            do {
                try await onApply(request.baseVersion, request.steering, request.followUp)
            } catch {
                if revertOnFailure {
                    editorState.revertLiveQueueToServer()
                }
                errorText = userFacingQueueError(error, revertOnFailure: revertOnFailure)
                if Self.isQueueVersionMismatch(error) {
                    await onRefresh()
                }
            }
        }
    }

    private func userFacingQueueError(_ error: Error, revertOnFailure: Bool) -> String {
        let message = error.localizedDescription
        if Self.isQueueVersionMismatch(error) {
            return revertOnFailure
                ? "Queue changed before your edit was saved. Review the latest queue and try again."
                : "Queue changed before your draft was saved. Review the latest queue or use your draft again."
        }
        return message
    }

    private static func isQueueVersionMismatch(_ error: Error) -> Bool {
        error.localizedDescription.localizedCaseInsensitiveContains("queue version mismatch")
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

private struct IconActionButton: View {
    let systemName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.themeComment)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.themeRecessedInset)
                )
        }
        .buttonStyle(.plain)
    }
}
