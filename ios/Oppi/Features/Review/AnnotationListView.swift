import SwiftUI

/// Standalone list of review annotations for a session.
/// Grouped by file, each with code snippet, severity badge, and thread preview.
///
/// Triage actions (accept / reject / fix) are accessible via swipe actions and
/// context menus — the standard iOS pattern for item-level actions.
struct AnnotationListView: View {
    @Environment(ServerConnection.self) private var connection
    @Environment(\.theme) private var theme

    @State private var store: AnnotationStore
    @State private var expandedAnnotationId: String?
    @State private var replyDrafts: [String: String] = [:]
    @State private var isFixInFlight = false

    /// Called when a fix session is created. Parent should dismiss sheet and navigate.
    var onFixDispatched: ((ReviewSessionNavDestination) -> Void)?

    init(sessionId: String, workspaceId: String, onFixDispatched: ((ReviewSessionNavDestination) -> Void)? = nil) {
        _store = State(initialValue: AnnotationStore(sessionId: sessionId, workspaceId: workspaceId))
        self.onFixDispatched = onFixDispatched
    }

    var body: some View {
        Group {
            if store.isLoading && store.annotations.isEmpty {
                ProgressView("Loading annotations…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = store.error, store.annotations.isEmpty {
                ContentUnavailableView(
                    "Could Not Load",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
            } else if store.annotations.isEmpty {
                ContentUnavailableView(
                    "No Findings",
                    systemImage: "checkmark.circle",
                    description: Text("The review produced no annotations.")
                )
            } else {
                annotationList
            }
        }
        .navigationTitle("Review Findings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 12) {
                    summaryBadge
                    if store.acceptedCount > 0 {
                        Button {
                            Task { await dispatchBatchFix() }
                        } label: {
                            Label("Fix \(store.acceptedCount)", systemImage: "wrench.and.screwdriver")
                                .font(.callout)
                                .fontWeight(.medium)
                        }
                        .disabled(isFixInFlight)
                    }
                }
            }
        }
        .overlay {
            if isFixInFlight {
                ProgressView("Starting fix session…")
                    .padding()
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .task {
            guard let api = connection.apiClient else {
                store.setOffline()
                return
            }
            await store.load(api: api)
        }
    }

    // MARK: - List

    private var annotationList: some View {
        List {
            ForEach(store.annotationsByFile, id: \.file) { group in
                Section {
                    ForEach(group.annotations) { annotation in
                        annotationRow(annotation)
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                if annotation.isPending {
                                    Button {
                                        Task {
                                            guard let api = connection.apiClient else { return }
                                            await store.resolve(
                                                annotationId: annotation.id,
                                                resolution: "accepted",
                                                api: api
                                            )
                                        }
                                    } label: {
                                        Label("Accept", systemImage: "checkmark")
                                    }
                                    .tint(.green)
                                }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                if annotation.isPending {
                                    Button(role: .destructive) {
                                        Task {
                                            guard let api = connection.apiClient else { return }
                                            await store.resolve(
                                                annotationId: annotation.id,
                                                resolution: "rejected",
                                                api: api
                                            )
                                        }
                                    } label: {
                                        Label("Reject", systemImage: "xmark")
                                    }
                                }

                                Button {
                                    Task { await dispatchSingleFix(annotation) }
                                } label: {
                                    Label("Fix", systemImage: "wrench")
                                }
                                .tint(theme.accent.blue)
                            }
                            .contextMenu {
                                if annotation.isPending {
                                    Button {
                                        Task {
                                            guard let api = connection.apiClient else { return }
                                            await store.resolve(
                                                annotationId: annotation.id,
                                                resolution: "accepted",
                                                api: api
                                            )
                                        }
                                    } label: {
                                        Label("Accept", systemImage: "checkmark.circle")
                                    }

                                    Button(role: .destructive) {
                                        Task {
                                            guard let api = connection.apiClient else { return }
                                            await store.resolve(
                                                annotationId: annotation.id,
                                                resolution: "rejected",
                                                api: api
                                            )
                                        }
                                    } label: {
                                        Label("Reject", systemImage: "xmark.circle")
                                    }

                                    Divider()
                                }

                                Button {
                                    Task { await dispatchSingleFix(annotation) }
                                } label: {
                                    Label("Fix This Finding", systemImage: "wrench.and.screwdriver")
                                }
                                .disabled(isFixInFlight)
                            }
                    }
                } header: {
                    fileHeader(group.file, count: group.annotations.count)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - File Header

    private func fileHeader(_ file: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(file)
                .font(.caption)
                .fontDesign(.monospaced)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text("\(count)")
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(.quaternary, in: Capsule())
        }
    }

    // MARK: - Annotation Row

    @ViewBuilder
    private func annotationRow(_ annotation: ReviewAnnotation) -> some View {
        let isExpanded = expandedAnnotationId == annotation.id

        VStack(alignment: .leading, spacing: 8) {
            // Header: severity + file:line + resolution
            HStack(spacing: 6) {
                severityBadge(annotation.severity)
                Text(annotation.lineRange)
                    .font(.caption)
                    .fontDesign(.monospaced)
                    .foregroundStyle(.secondary)
                Spacer()
                resolutionBadge(annotation.resolution)
            }

            // Code snippet
            Text(annotation.codeSnippet)
                .font(.caption)
                .fontDesign(.monospaced)
                .foregroundStyle(.secondary)
                .lineLimit(isExpanded ? nil : 3)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.bg.secondary.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 6))

            // First comment preview (collapsed) or full thread (expanded)
            if isExpanded {
                threadView(annotation)
            } else if let first = annotation.firstComment {
                Text(first.text)
                    .font(.callout)
                    .lineLimit(2)
                    .foregroundStyle(.primary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                if isExpanded {
                    expandedAnnotationId = nil
                } else {
                    expandedAnnotationId = annotation.id
                }
            }
        }
    }

    // MARK: - Thread

    private func threadView(_ annotation: ReviewAnnotation) -> some View {
        let draft = Binding<String>(
            get: { replyDrafts[annotation.id, default: ""] },
            set: { replyDrafts[annotation.id] = $0 }
        )
        let trimmed = draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)

        return VStack(alignment: .leading, spacing: 6) {
            ForEach(annotation.comments) { comment in
                commentBubble(comment)
            }

            // Reply field
            HStack(spacing: 8) {
                TextField("Reply…", text: draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout)
                    .lineLimit(1...4)

                Button {
                    Task {
                        guard let api = connection.apiClient else { return }
                        guard !trimmed.isEmpty else { return }
                        replyDrafts[annotation.id] = ""
                        await store.addComment(annotationId: annotation.id, text: trimmed, api: api)
                    }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title3)
                }
                .disabled(trimmed.isEmpty)
            }
        }
    }

    private func commentBubble(_ comment: AnnotationComment) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: comment.isAgent ? "cpu" : "person.fill")
                .font(.caption2)
                .foregroundStyle(comment.isAgent ? .blue : .green)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(comment.isAgent ? "Agent" : "You")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Text(comment.text)
                    .font(.callout)
                    .foregroundStyle(.primary)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Badges

    private func severityBadge(_ severity: String) -> some View {
        let fgColor = severityFgColor(severity)
        let bgColor = fgColor.opacity(0.12)
        let icon = severityIcon(severity)
        return Label {
            Text(severity)
                .font(.caption2)
                .fontWeight(.semibold)
                .textCase(.uppercase)
        } icon: {
            Image(systemName: icon)
                .font(.caption2)
        }
        .foregroundStyle(fgColor)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(bgColor, in: Capsule())
    }

    private func resolutionBadge(_ resolution: String) -> some View {
        let fgColor = resolutionFgColor(resolution)
        let bgColor = fgColor.opacity(resolution == "pending" ? 0.08 : 0.12)
        let icon = resolutionIcon(resolution)
        let text = resolutionText(resolution)
        return Label {
            Text(text)
                .font(.caption2)
                .fontWeight(.medium)
        } icon: {
            Image(systemName: icon)
                .font(.caption2)
        }
        .foregroundStyle(fgColor)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(bgColor, in: Capsule())
    }

    private var summaryBadge: some View {
        HStack(spacing: 8) {
            if store.pendingCount > 0 {
                Text("\(store.pendingCount) pending")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if store.acceptedCount > 0 {
                Text("\(store.acceptedCount) accepted")
                    .font(.caption2)
                    .foregroundStyle(.green)
            }
        }
    }

    private func severityFgColor(_ severity: String) -> Color {
        switch severity {
        case "error": .red
        case "warn": .orange
        default: .blue
        }
    }

    private func severityIcon(_ severity: String) -> String {
        switch severity {
        case "error": "exclamationmark.triangle.fill"
        case "warn": "exclamationmark.triangle"
        default: "info.circle"
        }
    }

    private func resolutionFgColor(_ resolution: String) -> Color {
        switch resolution {
        case "accepted": .green
        case "rejected": .red
        default: .secondary
        }
    }

    private func resolutionIcon(_ resolution: String) -> String {
        switch resolution {
        case "accepted": "checkmark.circle.fill"
        case "rejected": "xmark.circle.fill"
        default: "clock"
        }
    }

    private func resolutionText(_ resolution: String) -> String {
        switch resolution {
        case "accepted": "Accepted"
        case "rejected": "Rejected"
        default: "Pending"
        }
    }

    // MARK: - Fix Dispatch

    private func dispatchSingleFix(_ annotation: ReviewAnnotation) async {
        guard let api = connection.apiClient else { return }
        isFixInFlight = true
        if let dest = await store.dispatchFix(annotationId: annotation.id, api: api) {
            onFixDispatched?(dest)
        }
        isFixInFlight = false
    }

    private func dispatchBatchFix() async {
        guard let api = connection.apiClient else { return }
        isFixInFlight = true
        if let dest = await store.dispatchBatchFix(api: api) {
            onFixDispatched?(dest)
        }
        isFixInFlight = false
    }
}
