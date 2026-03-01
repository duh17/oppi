import SwiftUI

struct MessageQueueContainer: View {
    let queue: MessageQueueState
    @Binding var busyStreamingBehavior: StreamingBehavior
    let onApply: (_ baseVersion: Int, _ steering: [MessageQueueDraftItem], _ followUp: [MessageQueueDraftItem]) async throws -> Void
    let onRefresh: () async -> Void

    @State private var isExpanded = false
    @State private var baseVersion = 0
    @State private var draftSteering: [MessageQueueItem] = []
    @State private var draftFollowUp: [MessageQueueItem] = []
    @State private var isDirty = false
    @State private var isApplying = false
    @State private var isRefreshing = false
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            if isExpanded {
                busyModePicker

                if draftSteering.isEmpty && draftFollowUp.isEmpty {
                    Text("Queue is empty")
                        .font(.caption)
                        .foregroundStyle(.themeComment)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                } else {
                    queueSection(
                        title: "Steering Queue",
                        kind: .steer,
                        items: draftSteering
                    )
                    queueSection(
                        title: "Follow-up Queue",
                        kind: .followUp,
                        items: draftFollowUp
                    )
                }

                if let errorText, !errorText.isEmpty {
                    Text(errorText)
                        .font(.caption)
                        .foregroundStyle(.themeRed)
                        .frame(maxWidth: .infinity, alignment: .leading)
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
            resetDraft(from: queue)
        }
        .onChange(of: queue) { _, latestQueue in
            if !isDirty || !isExpanded {
                resetDraft(from: latestQueue)
            }
        }
    }

    private var totalCount: Int {
        draftSteering.count + draftFollowUp.count
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

                    Text("\(draftSteering.count) steering • \(draftFollowUp.count) follow-up")
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
                moveItem(kind: kind, from: index, direction: -1)
            }
            .disabled(!canMove(kind: kind, index: index, direction: -1))

            IconActionButton(systemName: "arrow.down") {
                moveItem(kind: kind, from: index, direction: 1)
            }
            .disabled(!canMove(kind: kind, index: index, direction: 1))

            IconActionButton(systemName: kind == .steer ? "arrow.down.right" : "arrow.up.left") {
                moveBetweenQueues(kind: kind, index: index)
            }

            IconActionButton(systemName: "trash") {
                deleteItem(kind: kind, index: index)
            }
        }
    }

    private var footerActions: some View {
        HStack(spacing: 8) {
            if isRefreshing {
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

            Button("Discard") {
                resetDraft(from: queue)
            }
            .font(.caption)
            .disabled(!isDirty || isApplying)

            Button {
                applyDraft()
            } label: {
                if isApplying {
                    ProgressView()
                        .controlSize(.mini)
                        .padding(.horizontal, 4)
                } else {
                    Text("Apply")
                        .font(.caption.weight(.semibold))
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.themeBlue)
            .disabled(!isDirty || isApplying)
        }
    }

    private func queueItems(for kind: MessageQueueKind) -> [MessageQueueItem] {
        switch kind {
        case .steer:
            return draftSteering
        case .followUp:
            return draftFollowUp
        }
    }

    private func setQueueItems(_ items: [MessageQueueItem], for kind: MessageQueueKind) {
        switch kind {
        case .steer:
            draftSteering = items
        case .followUp:
            draftFollowUp = items
        }
    }

    private func messageBinding(kind: MessageQueueKind, index: Int) -> Binding<String> {
        Binding(
            get: {
                queueItems(for: kind)[index].message
            },
            set: { newValue in
                var items = queueItems(for: kind)
                guard items.indices.contains(index) else { return }
                items[index].message = newValue
                setQueueItems(items, for: kind)
                isDirty = true
                errorText = nil
            }
        )
    }

    private func canMove(kind: MessageQueueKind, index: Int, direction: Int) -> Bool {
        let items = queueItems(for: kind)
        let target = index + direction
        return items.indices.contains(index) && items.indices.contains(target)
    }

    private func moveItem(kind: MessageQueueKind, from index: Int, direction: Int) {
        var items = queueItems(for: kind)
        let target = index + direction
        guard items.indices.contains(index), items.indices.contains(target) else { return }
        items.swapAt(index, target)
        setQueueItems(items, for: kind)
        isDirty = true
        errorText = nil
    }

    private func moveBetweenQueues(kind: MessageQueueKind, index: Int) {
        switch kind {
        case .steer:
            guard draftSteering.indices.contains(index) else { return }
            let item = draftSteering.remove(at: index)
            draftFollowUp.append(item)
        case .followUp:
            guard draftFollowUp.indices.contains(index) else { return }
            let item = draftFollowUp.remove(at: index)
            draftSteering.append(item)
        }
        isDirty = true
        errorText = nil
    }

    private func deleteItem(kind: MessageQueueKind, index: Int) {
        switch kind {
        case .steer:
            guard draftSteering.indices.contains(index) else { return }
            draftSteering.remove(at: index)
        case .followUp:
            guard draftFollowUp.indices.contains(index) else { return }
            draftFollowUp.remove(at: index)
        }
        isDirty = true
        errorText = nil
    }

    private func refreshQueue() {
        guard !isRefreshing else { return }
        isRefreshing = true
        errorText = nil

        Task { @MainActor in
            defer { isRefreshing = false }
            await onRefresh()
        }
    }

    private func applyDraft() {
        guard !isApplying else { return }
        isApplying = true
        errorText = nil

        let steering = draftSteering.map {
            MessageQueueDraftItem(
                id: $0.id,
                message: $0.message,
                images: $0.images,
                createdAt: $0.createdAt
            )
        }
        let followUp = draftFollowUp.map {
            MessageQueueDraftItem(
                id: $0.id,
                message: $0.message,
                images: $0.images,
                createdAt: $0.createdAt
            )
        }

        Task { @MainActor in
            defer { isApplying = false }
            do {
                try await onApply(baseVersion, steering, followUp)
                isDirty = false
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    private func resetDraft(from state: MessageQueueState) {
        baseVersion = state.version
        draftSteering = state.steering
        draftFollowUp = state.followUp
        isDirty = false
        errorText = nil
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
