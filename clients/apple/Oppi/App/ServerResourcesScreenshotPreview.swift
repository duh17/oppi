#if DEBUG
import Charts
import SwiftUI

/// Screenshot-only fixtures for server-scoped resource states that are unsafe or
/// unavailable to seed in the paired E2E server. The E2E journey separately
/// proves the real temporary-server Oppi configuration mutation.
struct ServerResourcesScreenshotPreview: View {
    enum Screen {
        case skills
        case extensions
        case cachedOffline
        case oppi
        case oppiPending
        case skillDetail
        case extensionDetail
        case oppiDetail
        case usageStates
        case toolActivity
        case themeSwitch
    }

    let screen: Screen
    let themeID: ThemeID

    init(screen: Screen, themeID: ThemeID = .dark) {
        self.screen = screen
        self.themeID = themeID
        ThemeRuntimeState.setThemeID(themeID)
    }

    var body: some View {
        content
            .environment(\.theme, themeID.appTheme)
            .environment(\.themeID, themeID)
            .tint(.themeBlue)
            .preferredColorScheme(themeID.preferredColorScheme)
            .onAppear {
                // Keep the preview's runtime palette aligned with the
                // environment injected into every mounted child.
                ThemeRuntimeState.setThemeID(themeID)
            }
    }

    @ViewBuilder
    private var content: some View {
        switch screen {
        case .skills:
            ResourceCatalogPreview(kind: .skills, cachedOffline: false)
        case .extensions:
            ResourceCatalogPreview(kind: .extensions, cachedOffline: false)
        case .cachedOffline:
            ResourceCatalogPreview(kind: .extensions, cachedOffline: true)
        case .oppi:
            OppiConfigurationPreview(isPending: false)
        case .oppiPending:
            OppiConfigurationPreview(isPending: true)
        case .skillDetail:
            ResourceDetailPreview(kind: .skill, disabled: true)
        case .extensionDetail:
            ResourceDetailPreview(kind: .normalExtension, disabled: true)
        case .oppiDetail:
            ResourceDetailPreview(kind: .oppi, disabled: true)
        case .usageStates:
            UsageStatesPreview()
        case .toolActivity:
            ToolActivityPreview()
        case .themeSwitch:
            LiveThemeSwitchPreview()
        }
    }
}

private struct ResourceCatalogPreview: View {
    enum Kind {
        case skills
        case extensions

        var title: String { self == .skills ? "Skills" : "Extensions" }
        var searchPrompt: String { self == .skills ? "Search skills" : "Search extensions" }
    }

    let kind: Kind
    let cachedOffline: Bool
    @State private var search = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("Preview Server", systemImage: "server.rack")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.themeFg)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Current server: Preview Server")
                        .accessibilityValue(cachedOffline ? "Offline" : "Connected")
                        .accessibilityIdentifier("serverResources.serverScope")
                }
                .themedListRowBackground()

                if cachedOffline {
                    Section {
                        Label(
                            "Showing cached settings for Preview Server. Pull to retry.",
                            systemImage: "exclamationmark.arrow.triangle.2.circlepath"
                        )
                        .font(.subheadline)
                        .foregroundStyle(.themeOrange)
                        .accessibilityIdentifier("serverResources.cachedWarning")
                    }
                    .themedListRowBackground()
                }

                switch kind {
                case .skills:
                    skillsSections
                case .extensions:
                    extensionSections
                }
            }
            .listStyle(.insetGrouped)
            .themedListSurface()
            .foregroundStyle(.themeFg)
            .tint(.themeBlue)
            .navigationTitle(kind.title)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: kind.searchPrompt)
        }
        .accessibilityIdentifier("screenshot.ready")
    }

    @ViewBuilder
    private var skillsSections: some View {
        Section("Needs Attention") {
            catalogRow(
                id: "serverResources.skills.error",
                title: "Release checks",
                subtitle: "Invalid frontmatter prevented this skill from loading.",
                provenance: "~/.pi/agent/skills",
                state: "Error",
                isError: true
            )
        }
        .themedListRowBackground()
        Section("Enabled") {
            catalogRow(
                id: "serverResources.skills.release",
                title: "Release", subtitle: "Review release readiness before shipping.",
                provenance: "~/.pi/agent/skills", state: "Enabled", isError: false
            )
        }
        .themedListRowBackground()
        Section("Disabled") {
            catalogRow(
                id: "serverResources.skills.research",
                title: "Deep research", subtitle: "Source-backed, multi-step web research.",
                provenance: "Pi user settings", state: "Disabled", isError: false
            )
        }
        .themedListRowBackground()
    }

    @ViewBuilder
    private var extensionSections: some View {
        Section("Built-in") {
            catalogRow(
                id: "serverResources.extensions.oppi",
                title: "Oppi", subtitle: "Server-owned Oppi command extension.",
                provenance: "Built-in extension", state: "On", isError: false
            )
        }
        .themedListRowBackground()
        Section("Needs Attention") {
            catalogRow(
                id: "serverResources.extensions.error",
                title: "Review helper", subtitle: "Extension could not be loaded.",
                provenance: "Pi user settings", state: "Error", isError: true
            )
        }
        .themedListRowBackground()
        Section("Enabled Pi Extensions") {
            catalogRow(
                id: "serverResources.extensions.workflow",
                title: "Workflow", subtitle: "Coordinates local automation.",
                provenance: "~/.pi/agent/extensions", state: "On", isError: false
            )
        }
        .themedListRowBackground()
    }

    private func catalogRow(
        id: String,
        title: String,
        subtitle: String,
        provenance: String,
        state: String,
        isError: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: kind == .skills ? "sparkles.rectangle.stack" : "puzzlepiece.extension")
                .font(.title3)
                .foregroundStyle(.themeBlue)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.themeFg)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.themeComment)
                Text(provenance)
                    .font(.caption)
                    .foregroundStyle(.themeComment)
                Label(state, systemImage: isError ? "exclamationmark.triangle.fill" : "checkmark.circle")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(isError ? .themeOrange : .themeComment)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.forward")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.themeComment)
                .accessibilityHidden(true)
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(provenance), \(state)")
        .accessibilityIdentifier(id)
    }
}

private struct OppiConfigurationPreview: View {
    let isPending: Bool
    @State private var enabled = true
    @State private var policy: OppiApprovalPolicy = .confirmDestructiveOnly
    @State private var saved = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Oppi")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.themeFg)
                        Text("Built-in extension")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.themeComment)
                        Text("Lets Pi inspect and manage this Oppi server with the allowlisted oppi tool.")
                            .font(.body)
                            .foregroundStyle(.themeComment)
                    }
                    .accessibilityIdentifier("serverResources.oppi.identity")
                }
                .themedListRowBackground()

                ObservedUsageSection(
                    requestKey: ResourceUsageRequestKey(
                        serverId: "preview-server",
                        subject: ResourceUsageSubject(kind: .extension, id: "oppi")
                    ),
                    timezone: "UTC"
                ) { range, _ in
                    observedUsage(range: range)
                }

                Section("Availability") {
                    Toggle("Enable Oppi Extension", isOn: $enabled)
                        .disabled(isPending)
                        .accessibilityLabel("Enable Oppi extension on Preview Server")
                        .accessibilityIdentifier("extensions.oppi.enabled")
                    Text("Adds the oppi tool to new non-sandbox Pi sessions managed by this server. It does not change sandbox, standalone, or terminal-owned Pi sessions.")
                        .font(.footnote)
                        .foregroundStyle(.themeComment)
                }
                .themedListRowBackground()

                Section("Approval Behavior") {
                    approvalChoice(.confirmDestructiveOnly)
                    approvalChoice(.confirmAllChanges)
                    approvalChoice(.readOnly)
                    Text("Selected: \(OppiApprovalPolicyPresentation(policy).title)")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.themeBlue)
                        .accessibilityIdentifier("serverResources.oppi.selectedPolicy")

                    if isPending {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Saving approval behavior…")
                        }
                        .font(.footnote)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("serverResources.oppi.pending")
                    }
                }
                .themedListRowBackground()

                if saved {
                    Section {
                        Text("Saved on Preview Server.")
                            .font(.footnote)
                            .foregroundStyle(.themeGreen)
                            .accessibilityIdentifier("extensions.oppi.savedMessage")
                    }
                    .themedListRowBackground()
                }
            }
            .listStyle(.insetGrouped)
            .themedListSurface()
            .foregroundStyle(.themeFg)
            .tint(.themeBlue)
            .navigationTitle("Oppi")
            .navigationBarTitleDisplayMode(.inline)
        }
        .accessibilityIdentifier("screenshot.ready")
    }

    private func observedUsage(range: ResourceUsageRange) -> ResourceUsageResponse {
        ResourceUsagePreviewFixtures.response(
            subject: ResourceUsageSubject(kind: .extension, id: "oppi"),
            range: range
        )
    }

    private func approvalChoice(_ candidate: OppiApprovalPolicy) -> some View {
        let presentation = OppiApprovalPolicyPresentation(candidate)
        let selected = policy == candidate
        return Button {
            guard !isPending else { return }
            policy = candidate
            saved = true
        } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(presentation.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.themeFg)
                    Text(presentation.consequence)
                        .font(.footnote)
                        .foregroundStyle(.themeComment)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if selected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.themeBlue)
                        .accessibilityHidden(true)
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled || isPending)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("extensions.oppi.policy.\(candidate.rawValue)")
    }
}

enum ResourceUsagePreviewFixtures {
    static let backfillStatus = ResourceUsageBackfillStatus(
        status: .complete,
        totalSources: 42,
        processedSources: 42,
        completedSources: 42,
        failedSources: 0,
        processedBytes: 1_048_576,
        processedLines: 1_000,
        historicalEvents: 15,
        corruptLines: 0,
        oversizedLines: 0,
        startedAt: 1_771_180_300_000,
        updatedAt: 1_771_180_400_000,
        lastCompletedAt: 1_771_180_400_000,
        lastError: nil,
        canStart: false
    )
    static let serverId = "preview-server"

    static func key(
        kind: ResourceUsageSubject.Kind,
        id: String? = nil
    ) -> ResourceUsageRequestKey {
        ResourceUsageRequestKey(
            serverId: serverId,
            subject: ResourceUsageSubject(kind: kind, id: id)
        )
    }

    static func response(
        subject: ResourceUsageSubject,
        range: ResourceUsageRange,
        recordedActions: Int? = nil,
        partial: Bool = false,
        dailyCount: Int? = nil
    ) -> ResourceUsageResponse {
        let requestedActions = recordedActions ?? defaultRecordedActions(for: subject)
        let requestedDailyCount = dailyCount ?? defaultDailyCount(for: range)
        let dailyRowCount = max(1, requestedDailyCount)
        let source = eventSource(
            subject: subject,
            recordedActions: requestedActions,
            dailyRowCount: dailyRowCount
        )
        let daily = dailyRows(
            from: source,
            count: dailyRowCount
        )
        let breakdown = breakdownRows(from: source)
        let recordedActions = source.count

        return ResourceUsageResponse(
            subject: subject,
            rangeDays: range,
            timezone: "UTC",
            recordingStartedAt: 1_765_843_200_000,
            recordedActions: recordedActions,
            attribution: ResourceUsageAttribution(
                exactActions: recordedActions,
                inferredActions: 0,
                historicalActions: 0,
                liveActions: recordedActions
            ),
            distinctSessions: source.distinctSessionCount,
            activeDays: daily.filter { $0.actions > 0 }.count,
            lastRecordedAt: recordedActions == 0 ? nil : 1_771_180_400_000,
            retainedHistory: ResourceUsageRetainedHistory(
                retentionDays: 120,
                oldestRecordedAt: 1_768_588_400_000,
                lastRecordedAt: recordedActions == 0 ? nil : 1_771_180_400_000
            ),
            daily: daily,
            breakdown: breakdown,
            capture: ResourceUsageCaptureStatus(
                status: partial ? .degraded : .active,
                failedWrites: partial ? 1 : 0,
                droppedEvents: 0,
                lastCapturedAt: recordedActions == 0 ? nil : 1_771_180_400_000
            ),
            backfill: backfillStatus
        )
    }

    private struct Event: Sendable {
        let day: Int
        let session: Int
        let signal: ResourceUsageSignal
        let name: String
        let ownerKind: ResourceUsageOwnerKind
        let ownerId: String

        struct Identity: Sendable {
            let signal: ResourceUsageSignal
            let name: String
            let ownerKind: ResourceUsageOwnerKind
            let ownerId: String
        }

    }

    private struct EventSource: Sendable {
        let events: [Event]

        var count: Int { events.count }
        var distinctSessionCount: Int { Set(events.map(\.session)).count }
    }

    private static func eventSource(
        subject: ResourceUsageSubject,
        recordedActions: Int,
        dailyRowCount: Int
    ) -> EventSource {
        guard recordedActions > 0 else { return EventSource(events: []) }
        let dailyRowCount = max(1, dailyRowCount)

        let ownerKind: ResourceUsageOwnerKind
        let ownerId: String
        switch subject.kind {
        case .skill:
            ownerKind = .skill
            ownerId = subject.id ?? "skill"
        case .extension:
            ownerKind = .extension
            ownerId = subject.id ?? "extension"
        case .tools:
            ownerKind = .builtIn
            ownerId = "builtin"
        }

        let activeDayCount: Int
        switch subject.kind {
        case .skill: activeDayCount = min(7, dailyRowCount)
        case .extension: activeDayCount = min(3, dailyRowCount)
        case .tools: activeDayCount = min(4, dailyRowCount)
        }

        let events = (0..<recordedActions).map { index -> Event in
            let session: Int
            switch subject.kind {
            case .skill: session = index % 9
            case .extension: session = index % 4
            case .tools: session = index % 5
            }
            let day: Int
            if activeDayCount <= 1 {
                day = 0
            } else {
                day = (index % activeDayCount) * (dailyRowCount - 1) / (activeDayCount - 1)
            }
            let identity = eventIdentity(
                for: subject,
                index: index,
                ownerKind: ownerKind,
                ownerId: ownerId
            )
            return Event(
                day: day,
                session: session,
                signal: identity.signal,
                name: identity.name,
                ownerKind: identity.ownerKind,
                ownerId: identity.ownerId
            )
        }
        return EventSource(events: events)
    }

    private static func eventIdentity(
        for subject: ResourceUsageSubject,
        index: Int,
        ownerKind: ResourceUsageOwnerKind,
        ownerId: String
    ) -> Event.Identity {
        switch subject.kind {
        case .skill:
            let signal: ResourceUsageSignal = index % 5 == 0 ? .explicitActivation : .agentLoad
            return Event.Identity(
                signal: signal,
                name: subject.id ?? "skill",
                ownerKind: ownerKind,
                ownerId: ownerId
            )
        case .extension:
            return Event.Identity(
                signal: .toolInvocation,
                name: subject.id ?? "extension-tool",
                ownerKind: ownerKind,
                ownerId: ownerId
            )
        case .tools:
            if index.isMultiple(of: 2) {
                return Event.Identity(
                    signal: .toolInvocation,
                    name: "read",
                    ownerKind: .builtIn,
                    ownerId: "builtin"
                )
            }
            return Event.Identity(
                signal: .toolInvocation,
                name: "review",
                ownerKind: .extension,
                ownerId: "review-tools"
            )
        }
    }

    private static func defaultRecordedActions(for subject: ResourceUsageSubject) -> Int {
        switch subject.kind {
        case .skill: 18
        case .extension: 9
        case .tools: 15
        }
    }

    private static func defaultDailyCount(for range: ResourceUsageRange) -> Int {
        range.rawValue
    }

    private static func dailyRows(
        from source: EventSource,
        count: Int
    ) -> [ResourceUsageDailyRow] {
        let rows = (0..<count).map { index in
            let events = source.events.filter { $0.day == index }
            return ResourceUsageDailyRow(
                date: "preview-day-\(index + 1)",
                actions: events.count,
                sessions: Set(events.map(\.session)).count
            )
        }
        return rows
    }

    private static func breakdownRows(from source: EventSource) -> [ResourceUsageBreakdownRow] {
        let grouped = Dictionary(grouping: source.events) {
            "\($0.signal.rawValue)|\($0.ownerKind.rawValue)|\($0.ownerId)|\($0.name)"
        }
        return grouped.values
            .sorted { lhs, rhs in
                guard let left = lhs.first, let right = rhs.first else { return false }
                if left.name != right.name { return left.name < right.name }
                return left.signal.rawValue < right.signal.rawValue
            }
            .compactMap { events in
                guard let first = events.first else { return nil }
                return ResourceUsageBreakdownRow(
                    signal: first.signal,
                    name: first.name,
                    ownerKind: first.ownerKind,
                    ownerId: first.ownerId,
                    actions: events.count,
                    sessions: Set(events.map(\.session)).count
                )
            }
    }
}

private enum ResourceUsagePreviewError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        "Preview server rejected the usage request."
    }
}

private struct ResourceDetailPreview: View {
    enum Kind {
        case skill
        case normalExtension
        case oppi

        var title: String {
            switch self {
            case .skill: "Testing"
            case .normalExtension: "Review Helper"
            case .oppi: "Oppi"
            }
        }

        var subtitle: String {
            switch self {
            case .skill: "Skill"
            case .normalExtension: "Normal Extension"
            case .oppi: "Built-in extension"
            }
        }

        var subject: ResourceUsageSubject {
            switch self {
            case .skill:
                ResourceUsageSubject(kind: .skill, id: "testing")
            case .normalExtension:
                ResourceUsageSubject(kind: .extension, id: "review-helper")
            case .oppi:
                ResourceUsageSubject(kind: .extension, id: "oppi")
            }
        }
    }

    let kind: Kind
    let disabled: Bool

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(kind.title)
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.themeFg)
                        Text(kind.subtitle)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.themeComment)
                        Text(description)
                            .font(.body)
                            .foregroundStyle(.themeComment)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityIdentifier("resourceDetail.identity")
                    .themedListRowBackground()
                }
                .themedListRowBackground()

                ObservedUsageSection(
                    requestKey: ResourceUsagePreviewFixtures.key(
                        kind: kind.subject.kind,
                        id: kind.subject.id
                    ),
                    timezone: "UTC",
                    title: "Observed Usage",
                    identifier: "resourceDetail.usage",
                    startsExpanded: false,
                    initialRange: kind == .skill ? .ninetyDays : .thirtyDays
                ) { range, _ in
                    ResourceUsagePreviewFixtures.response(
                        subject: kind.subject,
                        range: range,
                        recordedActions: kind == .skill ? 18 : 11,
                        dailyCount: kind == .skill ? range.rawValue : nil
                    )
                }

                Section("Server Default") {
                    Toggle("Enable \(kind.title)", isOn: .constant(!disabled))
                        .disabled(disabled)
                        .accessibilityIdentifier("resourceDetail.disabledToggle")
                        .accessibilityValue(disabled ? "Disabled; historical activity retained" : "Enabled")
                        .themedListRowBackground()

                    Text(disabled
                        ? "This resource is disabled. Historical observed activity remains available for review."
                        : "This resource is available to new sessions.")
                        .font(.footnote)
                        .foregroundStyle(.themeComment)
                        .fixedSize(horizontal: false, vertical: true)
                        .themedListRowBackground()
                }
                .themedListRowBackground()

                Section("Source") {
                    LabeledContent("Provenance", value: provenance)
                        .themedListRowBackground()
                    LabeledContent("History", value: disabled ? "Retained" : "Recording")
                        .themedListRowBackground()
                }
                .themedListRowBackground()

                detailSection
            }
            .listStyle(.insetGrouped)
            .themedListSurface()
            .foregroundStyle(.themeFg)
            .tint(.themeBlue)
            .navigationTitle(kind.title)
            .navigationBarTitleDisplayMode(.inline)
        }
        .accessibilityIdentifier("screenshot.ready")
    }

    private var description: String {
        switch kind {
        case .skill:
            "A server-authored Testing Skill that records agent loads and explicit activations."
        case .normalExtension:
            "A normal Pi Extension with contributed tools and commands. It can be disabled without erasing its usage history."
        case .oppi:
            "Lets Pi inspect and manage this Oppi server with the allowlisted oppi tool."
        }
    }

    private var provenance: String {
        switch kind {
        case .skill: "Pi user settings"
        case .normalExtension: "Pi user settings"
        case .oppi: "Built-in extension"
        }
    }

    @ViewBuilder
    private var detailSection: some View {
        switch kind {
        case .skill:
            Section("Contents") {
                Text("12 files · Read-only server history")
                    .themedListRowBackground()
            }
            .themedListRowBackground()
        case .normalExtension:
            Section("Contributed Tools") {
                Text("review_changes — inspect changed files and summarize risk")
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .themedListRowBackground()
                Text("review_commands — prepare a review checklist for a session")
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .themedListRowBackground()
            }
            .themedListRowBackground()
        case .oppi:
            Section("Approval Behavior") {
                Text("Confirm destructive only")
                    .themedListRowBackground()
                Text("Reads run immediately; destructive mutations require explicit approval.")
                    .font(.footnote)
                    .foregroundStyle(.themeComment)
                    .fixedSize(horizontal: false, vertical: true)
                    .themedListRowBackground()
            }
            .themedListRowBackground()
        }
    }
}

private struct UsageStatesPreview: View {
    var body: some View {
        NavigationStack {
            List {
                Text("Empty history")
                    .font(.headline)
                    .accessibilityIdentifier("usageStates.empty.title")
                    .themedListRowBackground()
                ObservedUsageSection(
                    requestKey: ResourceUsagePreviewFixtures.key(kind: .skill, id: "empty"),
                    timezone: "UTC",
                    title: "Empty history",
                    identifier: "usageStates.empty",
                    startsExpanded: true
                ) { range, _ in
                    ResourceUsagePreviewFixtures.response(
                        subject: ResourceUsageSubject(kind: .skill, id: "empty"),
                        range: range,
                        recordedActions: 0
                    )
                }

                Text("Partial coverage")
                    .font(.headline)
                    .accessibilityIdentifier("usageStates.partial.title")
                    .themedListRowBackground()
                ObservedUsageSection(
                    requestKey: ResourceUsagePreviewFixtures.key(kind: .extension, id: "partial"),
                    timezone: "UTC",
                    title: "Partial coverage",
                    identifier: "usageStates.partial",
                    startsExpanded: true
                ) { range, _ in
                    ResourceUsagePreviewFixtures.response(
                        subject: ResourceUsageSubject(kind: .extension, id: "partial"),
                        range: range,
                        partial: true
                    )
                }

                Text("Loading")
                    .font(.headline)
                    .accessibilityIdentifier("usageStates.loading.title")
                    .themedListRowBackground()
                ObservedUsageSection(
                    requestKey: ResourceUsagePreviewFixtures.key(kind: .extension, id: "loading"),
                    timezone: "UTC",
                    title: "Loading",
                    identifier: "usageStates.loading",
                    startsExpanded: true
                ) { _, _ in
                    try await Task.sleep(for: .seconds(60))
                    return ResourceUsagePreviewFixtures.response(
                        subject: ResourceUsageSubject(kind: .extension, id: "loading"),
                        range: .thirtyDays
                    )
                }

                Text("Failure")
                    .font(.headline)
                    .accessibilityIdentifier("usageStates.failure.title")
                    .themedListRowBackground()
                ObservedUsageSection(
                    requestKey: ResourceUsagePreviewFixtures.key(kind: .extension, id: "failure"),
                    timezone: "UTC",
                    title: "Failure",
                    identifier: "usageStates.failure",
                    startsExpanded: true
                ) { _, _ in
                    throw ResourceUsagePreviewError.unavailable
                }
            }
            .listStyle(.insetGrouped)
            .themedListSurface()
            .foregroundStyle(.themeFg)
            .tint(.themeBlue)
            .navigationTitle("Usage States")
            .navigationBarTitleDisplayMode(.inline)
        }
        .accessibilityIdentifier("screenshot.ready")
    }
}

private struct ToolActivityPreview: View {
    var body: some View {
        NavigationStack {
            List {
                Section {
                    ToolActivitySection(
                        requestKey: ResourceUsagePreviewFixtures.key(kind: .tools),
                        timezone: "UTC",
                        startsExpanded: true,
                        initialRange: .ninetyDays
                    ) { range, _ in
                        ResourceUsagePreviewFixtures.response(
                            subject: ResourceUsageSubject(kind: .tools, id: nil),
                            range: range,
                            recordedActions: 15,
                            dailyCount: 90
                        )
                    } backfillStatusRequest: {
                        ResourceUsagePreviewFixtures.backfillStatus
                    } startBackfillRequest: {
                        ResourceUsagePreviewFixtures.backfillStatus
                    }
                    .themedListRowBackground()
                }
                .themedListRowBackground()
            }
            .listStyle(.insetGrouped)
            .themedListSurface()
            .foregroundStyle(.themeFg)
            .tint(.themeBlue)
            .navigationTitle("Tool Activity")
            .navigationBarTitleDisplayMode(.inline)
        }
        .accessibilityIdentifier("screenshot.ready")
    }
}

private struct LiveThemeSwitchPreview: View {
    private struct ChartPoint: Identifiable {
        let id: Int
        let value: Int
    }

    private static let chartPoints = [2, 5, 1, 6, 3, 7, 4].enumerated().map {
        ChartPoint(id: $0.offset, value: $0.element)
    }

    @State private var themeID: ThemeID = .dark
    @State private var isExpanded = true

    var body: some View {
        NavigationStack {
            List {
                Section("Mounted persistent surface") {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Review Helper")
                                .font(.body.weight(.semibold))
                            Text("Normal Extension · Disabled")
                                .font(.subheadline)
                                .foregroundStyle(.themeComment)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.themeComment)
                    }
                    .accessibilityIdentifier("themeSwitch.row")
                    .themedListRowBackground()
                    .listRowSeparatorTint(Color.themeComment.opacity(0.22))

                    Text("The mounted row separator follows the active theme.")
                        .font(.caption)
                        .foregroundStyle(.themeComment)
                        .accessibilityIdentifier("themeSwitch.separator")
                        .themedListRowBackground()
                        .listRowSeparatorTint(Color.themeComment.opacity(0.22))
                }
                .themedListRowBackground()

                Section("Persistent chart and disclosure") {
                    themeSwitchChart
                        .themedListRowBackground()

                    DisclosureGroup(isExpanded: $isExpanded) {
                        Text("Disclosure content remains mounted while the palette changes.")
                            .font(.caption)
                            .foregroundStyle(.themeComment)
                            .fixedSize(horizontal: false, vertical: true)
                    } label: {
                        Label("Usage Details", systemImage: "chart.bar")
                            .foregroundStyle(.themeFg)
                    }
                    .accessibilityIdentifier("themeSwitch.disclosure")
                    .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
                    .themedListRowBackground()
                }
                .themedListRowBackground()
            }
            .listStyle(.insetGrouped)
            .themedListSurface()
            .foregroundStyle(.themeFg)
            .tint(.themeBlue)
            .navigationTitle("Live Theme Switch")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(themeID == .dark ? "Switch to light" : "Switch to dark") {
                        let next: ThemeID = themeID == .dark ? .light : .dark
                        themeID = next
                        ThemeRuntimeState.setThemeID(next)
                    }
                    .accessibilityIdentifier("themeSwitch.toggle")
                }
            }
        }
        .environment(\.theme, themeID.appTheme)
        .environment(\.themeID, themeID)
        .preferredColorScheme(themeID.preferredColorScheme)
        .onAppear { ThemeRuntimeState.setThemeID(themeID) }
        .overlay(alignment: .bottomLeading) {
            Text(themeID.displayName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.themeFg)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.themeBgHighlight, in: Capsule())
                .accessibilityIdentifier("themeSwitch.state")
                .padding(12)
        }
        .accessibilityIdentifier("screenshot.ready")
    }

    private var themeSwitchChart: some View {
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(Self.chartPoints) { point in
                RoundedRectangle(cornerRadius: 2)
                    .fill(.themeComment)
                    .frame(maxWidth: .infinity)
                    .frame(height: CGFloat(point.value * 12))
            }
        }
        .frame(height: 110, alignment: .bottom)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Usage chart")
        .accessibilityIdentifier("themeSwitch.chart")
    }
}

#endif
