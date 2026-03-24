import SwiftUI

struct MessageQueueContainer: View {
    private struct StatusBannerModel {
        let title: String
        let message: String
        let color: Color
    }

    let queue: MessageQueueState
    @Binding var busyStreamingBehavior: StreamingBehavior
    let onApply: (_ baseVersion: Int, _ steering: [MessageQueueDraftItem], _ followUp: [MessageQueueDraftItem]) async throws -> Void
    let onRefresh: () async -> Void

    @State private var isExpanded = false
    @State private var editorState: MessageQueueEditorState
    @State private var isApplying = false
    @State private var isRefreshing = false
    @State private var errorText: String?

    init(
        queue: MessageQueueState,
        busyStreamingBehavior: Binding<StreamingBehavior>,
        onApply: @escaping (_ baseVersion: Int, _ steering: [MessageQueueDraftItem], _ followUp: [MessageQueueDraftItem]) async throws -> Void,
        onRefresh: @escaping () async -> Void
    ) {
        self.queue = queue
        _busyStreamingBehavior = busyStreamingBehavior
        self.onApply = onApply
        self.onRefresh = onRefresh
        _editorState = State(initialValue: MessageQueueEditorState(queue: queue))
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            if isExpanded {
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
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.themeFg.opacity(0.12), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.08), radius: 10, x: 0, y: 2)
        .accessibilityElement(children: .contain)
        .onAppear {
            editorState = MessageQueueEditorState(queue: queue)
        }
        .onChange(of: queue) { _, latestQueue in
            editorState.receiveServerQueue(latestQueue, isExpanded: isExpanded)
        }
    }

    private var header: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Message Queue")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.themeFg)

                    Text("\(displayedQueue.steering.count) steering • \(displayedQueue.followUp.count) follow-up")
                        .font(.caption2)
                        .foregroundStyle(.themeComment)
                }

                Spacer(minLength: 8)

                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.themeComment)
                    .frame(width: 28, height: 28)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("chat.messageQueue.toggle")
        .accessibilityLabel(isExpanded ? "Collapse message queue" : "Expand message queue")
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
                .fill(Color.themeBg.opacity(0.30))
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
        let binding = messageBinding(kind: kind, index: index)
        HStack(spacing: 8) {
            TextField("Queued message", text: binding, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.caption)
                .lineLimit(1...3)
                .disabled(isApplying || isRefreshing)
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.themeBg.opacity(0.30))
                )

            rowActions(kind: kind, index: index)
        }
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
                        .fill(Color.themeBg.opacity(0.30))
                )
        }
        .buttonStyle(.plain)
    }
}
