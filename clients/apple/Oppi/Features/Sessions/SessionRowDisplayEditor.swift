import SwiftUI

// MARK: - Preview subject

/// What the editor previews: one root row and, for a launch tree, its Thread
/// strip. Built once when the editor opens and frozen while it is open. It
/// is built from data already in memory, never fetched or persisted.
struct SessionRowPreviewSubject {
    struct Thread {
        let rollup: SessionThreadRollup
        let attentionMember: Session?
    }

    let presentation: SessionRowPresentation
    let thread: Thread?

    /// Illustrative rows for a thread whose root is Done while children work,
    /// ask a question, and finish. Nothing here comes from the user's sessions.
    static func sample(now: Date = Date()) -> SessionRowPreviewSubject {
        func session(
            _ id: String,
            _ name: String,
            status: SessionStatus,
            parent: String? = nil,
            startedAgo: TimeInterval,
            activeAgo: TimeInterval,
            cost: Double,
            model: String = "anthropic/claude-sonnet-5",
            changeStats: SessionChangeStats? = nil,
            contextTokens: Int? = nil
        ) -> Session {
            Session(
                id: "sample.\(id)",
                workspaceName: "shop-app",
                name: name,
                status: status,
                createdAt: now.addingTimeInterval(-startedAgo),
                lastActivity: now.addingTimeInterval(-activeAgo),
                currentTurnStartedAt: status == .busy ? now.addingTimeInterval(-95) : nil,
                model: model,
                messageCount: 24,
                tokens: TokenUsage(input: 0, output: 0),
                cost: cost,
                changeStats: changeStats,
                contextTokens: contextTokens,
                contextWindow: contextTokens == nil ? nil : 200_000,
                parentSessionId: parent.map { "sample.\($0)" }
            )
        }

        let root = session(
            "root", "Refactor checkout flow", status: .ready,
            startedAgo: 7_200, activeAgo: 180, cost: 3.14,
            changeStats: SessionChangeStats(
                mutatingToolCalls: 31, compactionCount: 2, filesChanged: 7,
                changedFiles: [], changedFilesOverflow: nil, addedLines: 210, removedLines: 64
            ),
            contextTokens: 96_000
        )
        let working = session(
            "tests", "Write migration tests", status: .busy, parent: "root",
            startedAgo: 1_800, activeAgo: 20, cost: 0.84
        )
        let question = session(
            "review", "Review API diff", status: .ready, parent: "root",
            startedAgo: 1_500, activeAgo: 240, cost: 0.51
        )
        let finished = session(
            "notes", "Draft changelog", status: .stopped, parent: "root",
            startedAgo: 3_600, activeAgo: 2_400, cost: 0.19
        )
        let rollup = SessionThreadGrouping.rollups(from: [root, working, question, finished])[0]
        return SessionRowPreviewSubject(
            presentation: SessionRowPresentationBuilder.make(
                session: root,
                workspaceContext: root.workspaceName
            ),
            thread: Thread(rollup: rollup, attentionMember: question)
        )
    }

    /// A snapshot of an already-loaded thread (or, when none has children, the
    /// first loaded session) from the cold list projection.
    @MainActor
    static func loaded(from connection: ServerConnection?) -> SessionRowPreviewSubject? {
        guard let connection else { return nil }
        let store = connection.sessionStore
        let rollups = SessionThreadGrouping.rollups(from: store.listProjectionSessions)
        guard let rollup = rollups.first(where: { !$0.descendants.isEmpty }) ?? rollups.first else {
            return nil
        }
        func askCount(_ sessionId: String) -> Int {
            SessionListAttentionMerger.askCount(
                listCount: store.listPendingAskCount(for: sessionId),
                hasPendingAsk: connection.askRequestStore.hasPending(for: sessionId),
                hasPendingExtensionDialog: connection.hasPendingExtensionDialog(for: sessionId)
            )
        }
        let root = rollup.root
        let workspaceName = root.workspaceId.flatMap { id in
            connection.workspaceStore.workspaces.first { $0.id == id }?.name
        }
        let presentation = SessionRowPresentationBuilder.make(
            session: root,
            pendingAskCount: askCount(root.id),
            pendingAsk: connection.askRequestStore.pending(for: root.id),
            workspaceContext: SessionInboxSessionRouting.allSessionsContext(for: root, workspaceName: workspaceName),
            unreadCompletionAt: store.unreadCompletionDate(for: root.id),
            catalogModels: connection.chatState.cachedModels
        )
        return SessionRowPreviewSubject(
            presentation: presentation,
            thread: rollup.descendants.isEmpty
                ? nil
                : Thread(rollup: rollup, attentionMember: rollup.descendants.first { askCount($0.id) > 0 })
        )
    }
}

// MARK: - Editor

/// Customize Rows: one local draft, an inert preview drawn by the production
/// row and Thread strip, and explicit save. Done saves the draft; Cancel or
/// swiping the sheet away discards it. Restore Defaults only resets the draft.
struct SessionRowDisplayEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(ConnectionCoordinator.self) private var coordinator

    @State private var draft = AppPreferences.SessionRows.display
    @State private var sample = SessionRowPreviewSubject.sample()
    @State private var loaded: SessionRowPreviewSubject?
    @State private var didCaptureLoaded = false
    @State private var usesLoaded = false

    private var subject: SessionRowPreviewSubject {
        usesLoaded ? (loaded ?? sample) : sample
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                previewPane
                Form {
                    densitySection
                    detailsSection
                    threadSection
                    Section {
                        Button("Restore Defaults") {
                            draft = .standard
                        }
                        .disabled(draft == .standard)
                        .accessibilityIdentifier("sessionRows.restore")
                    } footer: {
                        Text("Restore Defaults changes this preview only until you tap Done.")
                    }
                }
                .themedListSurface()
                .accessibilityIdentifier("sessionRows.form")
            }
            .background(theme.bg.primary)
            .navigationTitle("Customize Rows")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("sessionRows.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        AppPreferences.SessionRows.setDisplay(draft)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("sessionRows.done")
                }
            }
        }
        .onAppear {
            guard !didCaptureLoaded else { return }
            didCaptureLoaded = true
            loaded = SessionRowPreviewSubject.loaded(from: coordinator.activeConnection)
        }
    }

    // MARK: Preview

    private var previewPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(usesLoaded ? "PREVIEW · SNAPSHOT OF A LOADED SESSION" : "PREVIEW · SAMPLE DATA")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.themeComment)
                .accessibilityIdentifier("sessionRows.preview.label")

            // Inert: the production row and strip with no navigation, swipe, or
            // other actions attached, and no hit testing.
            VStack(alignment: .leading, spacing: 6) {
                SessionRow(presentation: subject.presentation)
                if let thread = subject.thread {
                    SessionThreadStrip(rollup: thread.rollup, attentionMember: thread.attentionMember)
                        .padding(.leading, SessionThreadStrip.rowInset)
                }
            }
            .environment(\.sessionRowDisplay, draft)
            .allowsHitTesting(false)
            // Contain first: an identifier on a plain container overrides its children's.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("sessionRows.preview")

            if usesLoaded, subject.thread == nil {
                Text("This session has no child sessions, so thread options do not show here.")
                    .font(.footnote)
                    .foregroundStyle(.themeComment)
            } else if !usesLoaded {
                Text("Not your sessions. Nothing is fetched or opened for this preview.")
                    .font(.footnote)
                    .foregroundStyle(.themeComment)
            } else {
                Text("Already loaded on this device. Nothing is fetched or opened for this preview.")
                    .font(.footnote)
                    .foregroundStyle(.themeComment)
            }

            if loaded != nil {
                Picker("Preview data", selection: $usesLoaded) {
                    Text("Sample").tag(false)
                    Text("My session").tag(true)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("sessionRows.previewData")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.bg.primary)
        .overlay(alignment: .bottom) { Divider() }
    }

    // MARK: Controls

    private var densitySection: some View {
        Section {
            Picker("Density", selection: $draft.density) {
                ForEach(SessionRowDisplay.Density.allCases) { density in
                    Text(density.label).tag(density)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("sessionRows.density")
        } footer: {
            Text("Compact tightens spacing and joins details on one line only when they all fit. It never hides or shortens a detail you turned on.")
        }
    }

    private var detailsSection: some View {
        Section {
            toggle("Model", isOn: $draft.showsModel, id: "model")
            toggle("Time", isOn: $draft.showsTime, id: "time")
            toggle("Context usage", isOn: $draft.showsContextUsage, id: "context")
            toggle("Cost", isOn: $draft.showsCost, id: "cost")
            toggle("Files touched", isOn: $draft.showsFilesTouched, id: "files")
            toggle("Compactions", isOn: $draft.showsCompactions, id: "compactions")
        } header: {
            Text("Details")
        } footer: {
            Text("Details keep this order. Title, status, questions, Incognito, workspace, and search matches always show.")
        }
    }

    private var threadSection: some View {
        Section {
            toggle("Agent summary", isOn: $draft.showsThreadAgentSummary, id: "agentSummary")
            toggle("Lane graph", isOn: $draft.showsThreadLaneGraph, id: "laneGraph")
        } header: {
            Text("Thread rows")
        } footer: {
            Text("The Thread control, a child's question, and who is working always show. Cost in the Thread row follows Cost above.")
        }
    }

    private func toggle(_ title: String, isOn: Binding<Bool>, id: String) -> some View {
        Toggle(title, isOn: isOn)
            .accessibilityIdentifier("sessionRows.toggle.\(id)")
    }
}
