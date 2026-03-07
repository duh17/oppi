import SwiftUI

struct MessageQueueContainer: View {
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            if isExpanded {
                busyModePicker

                if let conflict = editorState.conflict {
                    statusBanner(title: conflict.title, message: conflict.message, color: .themeOrange)
                } else if editorState.isDraftMode {
                    statusBanner(title: "Unsaved text edits", message: "Save to replace the current queue with your updated draft.", color: .themeComment)
                } else if editorState.hasStashedDraft {
                    statusBanner(title: "Reviewing latest queue", message: "Your earlier draft is still available if you want to restore it.", color: .themeComment)
                }

                if let errorText, !errorText.isEmpty {
                    statusBanner(title: "Queue update failed", message: errorText, color: .themeRed)
                }

                if displayedQueue.steering.isEmpty && displayedQueue.followUp.isEmpty {
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
                .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
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
        let controlsDisabled = isApplying || isRefreshing

        return HStack(spacing: 4) {
            IconActionButton(systemName: "arrow.up") {
                let request = editorState.moveItem(kind: kind, from: index, direction: -1)
                if let request {
                    applyMutation(request, revertOnFailure: true)
                } else {
                    errorText = nil
                }
            }
            .disabled(controlsDisabled || !canMove(kind: kind, index: index, direction: -1))

            IconActionButton(systemName: "arrow.down") {
                let request = editorState.moveItem(kind: kind, from: index, direction: 1)
                if let request {
                    applyMutation(request, revertOnFailure: true)
                } else {
                    errorText = nil
                }
            }
            .disabled(controlsDisabled || !canMove(kind: kind, index: index, direction: 1))

            IconActionButton(systemName: kind == .steer ? "arrow.down.right" : "arrow.up.left") {
                let request = editorState.moveBetweenQueues(kind: kind, index: index)
                if let request {
                    applyMutation(request, revertOnFailure: true)
                } else {
                    errorText = nil
                }
            }
            .disabled(controlsDisabled)

            IconActionButton(systemName: "trash") {
                let request = editorState.deleteItem(kind: kind, index: index)
                if let request {
                    applyMutation(request, revertOnFailure: true)
                } else {
                    errorText = nil
                }
            }
            .disabled(controlsDisabled)
        }
    }

    private var footerActions: some View {
        HStack(spacing: 8) {
            if isRefreshing || isApplying {
                ProgressView()
                    .controlSize(.mini)
            }

            Button("Refresh") {
                refreshQueue()
            }
            .font(.caption)
            .disabled(isRefreshing || isApplying)
            .accessibilityIdentifier("chat.messageQueue.refresh")

            Spacer()

            if editorState.hasStashedDraft {
                Button("Restore draft") {
                    editorState.restoreDraft()
                    errorText = nil
                }
                .font(.caption)
                .disabled(isApplying || isRefreshing)
            }

            if editorState.isDraftMode {
                if let conflict = editorState.conflict {
                    Button(conflict.reviewActionTitle) {
                        editorState.reviewLatest()
                        errorText = nil
                    }
                    .font(.caption)
                    .disabled(isApplying || isRefreshing)

                    Button {
                        saveDraft()
                    } label: {
                        labelText(conflict.applyActionTitle)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.themeBlue)
                    .disabled(isApplying || isRefreshing)
                } else {
                    Button("Discard") {
                        editorState.discardDraft()
                        errorText = nil
                    }
                    .font(.caption)
                    .disabled(isApplying || isRefreshing)

                    Button {
                        saveDraft()
                    } label: {
                        labelText("Save")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.themeBlue)
                    .disabled(isApplying || isRefreshing)
                }
            }
        }
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

    private func refreshQueue() {
        guard !isRefreshing, !isApplying else { return }
        isRefreshing = true
        errorText = nil

        Task { @MainActor in
            defer { isRefreshing = false }
            await onRefresh()
        }
    }

    private func saveDraft() {
        guard let request = editorState.draftRequest(), !isApplying, !isRefreshing else { return }
        applyMutation(request, revertOnFailure: false)
    }

    private func applyMutation(_ request: MessageQueueMutationRequest, revertOnFailure: Bool) {
        guard !isApplying, !isRefreshing else { return }
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
